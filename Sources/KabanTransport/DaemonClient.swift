import Foundation
import KabanProtocol

public enum DaemonUpdate: Sendable, Equatable {
    case snapshot(Snapshot)
    case event(EventEnvelope)
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
