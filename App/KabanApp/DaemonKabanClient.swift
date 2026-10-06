import Foundation
import KabanProtocol
import KabanBoardCore
import KabanTransport

@MainActor final class DaemonKabanClient: KabanClient {
    let daemon: DaemonClient
    init(transport: any DaemonTransport) { daemon = DaemonClient(transport: transport) }
    func getSnapshot() async throws -> Snapshot { try await daemon.getSnapshot() }
    func send(_ command: Command, commandId: CommandID) async throws -> CommandResult {
        try await daemon.send(.init(commandId: commandId, command: command)).result
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
                        case .connection(let state): update = .connection(state)
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
