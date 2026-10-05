import Foundation
import KabanProtocol

public enum DaemonUpdate: Sendable, Equatable {
    case snapshot(Snapshot)
    case event(EventEnvelope)
    case replacement(SnapshotReplacement)
    case ephemeral(EphemeralEnvelope)
    case connection(DaemonConnectionState)
}

/// Pull subscription: drain bounded catch-up pages, then poll for committed live events.
/// Durable cursors make reconnect independent of in-memory listener registration.
public struct DaemonClient: Sendable {
    public let transport: any DaemonTransport
    public init(transport: any DaemonTransport) { self.transport = transport }

    private func request(_ operation: DaemonRequest.Operation) async throws -> DaemonResponse.Result {
        let response = try await transport.exchange(.init(operation))
        guard response.protocolVersion == KabanCoding.protocolVersion else {
            throw CommandError(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")
        }
        if case .error(let error) = response.result { throw error }
        return response.result
    }
    public func getSnapshot() async throws -> Snapshot {
        guard case .snapshot(let snapshot) = try await request(.snapshot), snapshot.seq >= 0,
              snapshot.protocolVersion == KabanCoding.protocolVersion else { throw DaemonTransportError.invalidReply }
        return snapshot
    }
    public func capabilities() async throws -> DaemonCapabilities {
        guard case .capabilities(let value) = try await request(.capabilities),
              Set(value.operations.map(\.name)).count == value.operations.count,
              Set(value.commands.map(\.name)).count == value.commands.count else { throw DaemonTransportError.invalidReply }
        return value
    }
    public func synchronize() async throws -> SnapshotReplacement {
        guard case .replacement(let value) = try await request(.synchronize),
              value.snapshot.seq >= 0, value.snapshot.protocolVersion == KabanCoding.protocolVersion,
              value.cursor.offset >= 0 else { throw DaemonTransportError.invalidReply }
        var offset: Int64 = 0
        for event in value.current {
            guard event.cursor.sessionId == value.cursor.sessionId, event.cursor.offset > offset,
                  event.cursor.offset <= value.cursor.offset, event.afterSeq >= 0,
                  event.afterSeq <= value.snapshot.seq else { throw DaemonTransportError.invalidReply }
            offset = event.cursor.offset
        }
        return value
    }
    public func ephemeral(after cursor: EphemeralCursor, limit: Int = DaemonWire.maxPageSize) async throws -> EphemeralPage {
        guard cursor.offset >= 0, (1...DaemonWire.maxPageSize).contains(limit) else {
            throw CommandError(code: "invalid_request", message: "Некорректный эфирный курсор или размер пакета.")
        }
        guard case .ephemeral(let page) = try await request(.ephemeral(after: cursor, limit: limit)),
              page.fromCursor == cursor, page.events.count <= limit, page.latestCursor.offset >= 0,
              page.nextCursor.sessionId == page.latestCursor.sessionId else { throw DaemonTransportError.invalidReply }
        if page.resetRequired {
            guard page.events.isEmpty, page.nextCursor == page.latestCursor else { throw DaemonTransportError.invalidReply }
            return page
        }
        guard page.latestCursor.sessionId == cursor.sessionId, cursor.offset <= page.latestCursor.offset else {
            throw DaemonTransportError.invalidReply
        }
        var offset = cursor.offset, barrier: Seq = 0
        for event in page.events {
            guard offset < Int64.max, event.cursor.sessionId == cursor.sessionId, event.cursor.offset == offset + 1,
                  event.cursor.offset <= page.latestCursor.offset, event.afterSeq >= barrier else { throw DaemonTransportError.invalidReply }
            offset = event.cursor.offset; barrier = event.afterSeq
        }
        guard page.nextCursor.offset == offset, page.events.count == limit || offset == page.latestCursor.offset else {
            throw DaemonTransportError.invalidReply
        }
        return page
    }
    public func readLog(runId: RunID, fromOffset: Int64, limit: Int = DaemonWire.maxPageSize) async throws -> LogPage {
        guard fromOffset >= 0, (1...DaemonWire.maxPageSize).contains(limit) else {
            throw CommandError(code: "invalid_request", message: "Некорректное смещение или размер пакета лога.")
        }
        guard case .log(let page) = try await request(.readLog(runId: runId, fromOffset: fromOffset, limit: limit)),
              page.batch.runId == runId, page.batch.fromOffset == fromOffset,
              page.availableFromOffset >= 0, page.availableFromOffset <= fromOffset,
              page.batch.nextOffset >= fromOffset, page.batch.nextOffset <= page.endOffset,
              page.batch.events.count <= limit,
              page.batch.nextOffset - fromOffset == Int64(page.batch.events.count),
              !page.batch.events.isEmpty || fromOffset == page.endOffset else { throw DaemonTransportError.invalidReply }
        return page
    }

    /// Poll normalized records until EOF. Failure ends explicitly; resume at the last consumed
    /// batch.nextOffset. Raw JSONL/byte offsets never enter this API.
    public func tailLog(runId: RunID, fromOffset: Int64) -> AsyncThrowingStream<LogBatch, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(2)) { continuation in
            let task = Task {
                var offset = fromOffset
                do {
                    while !Task.isCancelled {
                        let page = try await readLog(runId: runId, fromOffset: offset)
                        if !page.batch.events.isEmpty {
                            try Self.publish(page.batch, to: continuation)
                            offset = page.batch.nextOffset
                        }
                        if page.isComplete && offset == page.endOffset { break }
                        if offset == page.endOffset { try await Task.sleep(nanoseconds: 200_000_000) }
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// New session API is opt-in so existing consumers keep snapshot/event-only streams.
    /// A live restart/retention gap replaces BOTH durable state and current volatile values.
    public func sessionUpdates() -> AsyncThrowingStream<DaemonUpdate, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(DaemonWire.maxPageSize * 2)) { continuation in
            let task = Task {
                var seq: Seq?
                var liveCursor: EphemeralCursor?
                var connected = false
                var schedulerFlagsSeq: Seq = 0
                var backoff: UInt64 = 200_000_000
                func publish(_ update: DaemonUpdate) throws { try Self.publish(update, to: continuation) }
                func drainJournal(through barrier: Seq? = nil) async throws {
                    repeat {
                        let page = try await subscribe(fromSeq: seq!)
                        if page.resyncRequired { throw SessionResync.required }
                        for event in page.events {
                            try publish(.event(event)); seq = event.seq
                            if case .settingsChanged(let value) = event.event, value.schedulerFlags != nil { schedulerFlagsSeq = event.seq }
                        }
                        if let barrier, seq! >= barrier { return }
                        if seq == page.latestSeq {
                            if let barrier, seq! < barrier { throw DaemonTransportError.invalidReply }
                            return
                        }
                    } while !Task.isCancelled
                    throw CancellationError()
                }
                do {
                    try publish(.connection(.connecting))
                    while !Task.isCancelled {
                        do {
                            if seq == nil {
                                try publish(.connection(.synchronizing))
                                let replacement = try await synchronize()
                                try publish(.replacement(replacement))
                                seq = replacement.snapshot.seq; liveCursor = replacement.cursor
                                schedulerFlagsSeq = replacement.snapshot.seq
                            }
                            try await drainJournal()
                            let page = try await ephemeral(after: liveCursor!)
                            if page.resetRequired { throw SessionResync.required }
                            for event in page.events {
                                if event.afterSeq > seq! { try await drainJournal(through: event.afterSeq) }
                                if event.event == .resyncRequired { throw SessionResync.required }
                                var staleFlags = false
                                if case .schedulerFlagsChanged = event.event { staleFlags = event.afterSeq < schedulerFlagsSeq }
                                if !staleFlags { try publish(.ephemeral(event)) }
                                liveCursor = event.cursor
                            }
                            if !connected && page.nextCursor == page.latestCursor {
                                try publish(.connection(.connected)); connected = true
                            }
                            backoff = 200_000_000
                            if page.nextCursor == page.latestCursor { try await Task.sleep(nanoseconds: 200_000_000) }
                        } catch SessionResync.required {
                            seq = nil; liveCursor = nil; connected = false
                        } catch DaemonTransportError.connectionLost {
                            connected = false
                            try publish(.connection(.reconnecting(lastSeq: seq)))
                            try await Task.sleep(nanoseconds: backoff); backoff = min(backoff * 2, 5_000_000_000)
                        } catch DaemonTransportError.timedOut {
                            connected = false
                            try publish(.connection(.reconnecting(lastSeq: seq)))
                            try await Task.sleep(nanoseconds: backoff); backoff = min(backoff * 2, 5_000_000_000)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch {
                    // Preserve the original error, including overflow; failure state is best-effort
                    // because a saturated consumer cannot accept another buffered update.
                    let commandError = (error as? CommandError) ?? .init(code: "transport_failure", message: "Соединение с демоном прервано.")
                    _ = continuation.yield(.connection(.disconnected(commandError)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    private static func publish<T: Sendable>(_ value: T, to continuation: AsyncThrowingStream<T, Error>.Continuation) throws {
        switch continuation.yield(value) {
        case .enqueued: break
        case .dropped: throw DaemonTransportError.bufferOverflow
        case .terminated: throw CancellationError()
        @unknown default: throw DaemonTransportError.invalidReply
        }
    }
    public func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        // The first commit may have succeeded before the connection lost its reply.
        // Retry the exact envelope, including its commandId, only for transport failure.
        let response: DaemonResponse.Result
        do { response = try await request(.command(envelope)) }
        catch DaemonTransportError.connectionLost { response = try await request(.command(envelope)) }
        catch DaemonTransportError.timedOut { response = try await request(.command(envelope)) }
        guard case .command(let reply) = response, reply.commandId == envelope.commandId else { throw DaemonTransportError.invalidReply }
        return reply
    }
    public func subscribe(fromSeq: Seq, limit: Int = DaemonWire.maxPageSize) async throws -> JournalPage {
        guard fromSeq >= 0, (1...DaemonWire.maxPageSize).contains(limit) else {
            throw CommandError(code: "invalid_request", message: "Некорректный курсор или размер пакета журнала.")
        }
        guard case .events(let page) = try await request(.subscribe(fromSeq: fromSeq, limit: limit)),
              page.fromSeq == fromSeq, page.latestSeq >= 0, page.events.count <= limit else { throw DaemonTransportError.invalidReply }
        if page.resyncRequired {
            guard page.events.isEmpty else { throw DaemonTransportError.invalidReply }
            return page
        }
        var cursor = fromSeq
        guard cursor >= 0, cursor <= page.latestSeq else { throw DaemonTransportError.invalidReply }
        for event in page.events {
            guard cursor < Seq.max, event.seq == cursor + 1, event.seq <= page.latestSeq else { throw DaemonTransportError.invalidReply }
            cursor = event.seq
        }
        guard page.events.count == limit || cursor == page.latestSeq else { throw DaemonTransportError.invalidReply }
        return page
    }

    /// A resync emits an authoritative replacement snapshot before any newer events.
    /// Cancellation stops polling/backoff; malformed/domain responses finish the stream.
    public func updates(after initialSeq: Seq? = nil) -> AsyncThrowingStream<DaemonUpdate, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(DaemonWire.maxPageSize * 2)) { continuation in
            let task = Task {
                func publish(_ update: DaemonUpdate) throws {
                    switch continuation.yield(update) {
                    case .enqueued: break
                    case .dropped: throw DaemonTransportError.bufferOverflow
                    case .terminated: throw CancellationError()
                    @unknown default: throw DaemonTransportError.invalidReply
                    }
                }
                var cursor = initialSeq
                var backoff: UInt64 = 200_000_000
                do {
                    while !Task.isCancelled {
                        do {
                            if cursor == nil {
                                let snapshot = try await getSnapshot()
                                try publish(.snapshot(snapshot)); cursor = snapshot.seq
                            }
                            let page = try await subscribe(fromSeq: cursor!)
                            if page.resyncRequired { cursor = nil; continue }
                            for event in page.events {
                                try publish(.event(event)); cursor = event.seq
                            }
                            backoff = 200_000_000
                            if cursor == page.latestSeq { try await Task.sleep(nanoseconds: 200_000_000) }
                        } catch DaemonTransportError.connectionLost {
                            try await Task.sleep(nanoseconds: backoff)
                            backoff = min(backoff * 2, 5_000_000_000)
                        } catch DaemonTransportError.timedOut {
                            try await Task.sleep(nanoseconds: backoff)
                            backoff = min(backoff * 2, 5_000_000_000)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
private enum SessionResync: Error { case required }
