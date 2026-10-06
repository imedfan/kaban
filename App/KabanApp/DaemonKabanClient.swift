import Foundation
import KabanProtocol
import KabanBoardCore
import KabanTransport

@MainActor final class DaemonKabanClient: KabanClient {
    let daemon: DaemonClient
    init(transport: any DaemonTransport) { daemon = DaemonClient(transport: transport) }
    func getSnapshot() async throws -> Snapshot { try await daemon.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await daemon.synchronize() }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply { try await daemon.send(envelope) }
    func capabilities() async throws -> DaemonCapabilities { try await daemon.capabilities() }
    func readLog(runId: RunID, fromOffset: Int64, limit: Int) async throws -> LogPage {
        try await daemon.readLog(runId: runId, fromOffset: fromOffset, limit: limit)
    }
    func tailLog(runId: RunID, fromOffset: Int64) -> AsyncThrowingStream<LogBatch, Error> {
        daemon.tailLog(runId: runId, fromOffset: fromOffset)
    }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> {
        let stream = daemon.sessionUpdates()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(DaemonWire.maxPageSize * 2)) { continuation in
            let task = Task {
                do {
                    for try await value in stream {
                        let update: KabanClientUpdate
                        switch value {
                        case .event(let event): update = .event(event)
                        case .replacement(let replacement): update = .replacement(replacement)
                        case .snapshot: throw DaemonTransportError.invalidReply
                        case .connection(let state):
                            if state == .connected {
                                let capabilities = try await daemon.capabilities()
                                try capabilities.requireSession()
                                if case .dropped = continuation.yield(.capabilities(capabilities)) { throw DaemonTransportError.bufferOverflow }
                            }
                            update = .connection(state)
                        case .ephemeral(let event): update = .ephemeral(event)
                        }
                        if case .dropped = continuation.yield(update) { throw DaemonTransportError.bufferOverflow }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    func events() -> AsyncStream<EventEnvelope> {
        let stream = updates()
        return AsyncStream { continuation in
            let task = Task {
                do { for try await value in stream { if case .event(let event) = value { continuation.yield(event) } } }
                catch { /* Rich updates report connection failure to the store. */ }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
