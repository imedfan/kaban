import Foundation
import XCTest
import KabanProtocol
import KabanTransport
import KabanBoardCore
@testable import KabanDaemonCore

extension WireCommandTests {
    @MainActor func testReviewAcceptedBeforeLostReplyReconcilesAfterReopenAndRetention() async throws {
        let (root, store) = try fixture()
        _ = try create("review-once", in: store); try review("review-once", in: store)
        let storage = MemoryKeyValueStore(), envelope = CommandEnvelope(command: .approve(taskId: "review-once"))
        let journal = try ClientCommandJournal(storage: storage, key: "wire")
        try journal.begin(envelope)
        let original = try store.execute(envelope)
        XCTAssertEqual(original.result, .ok)
        try journal.markUncertain(envelope.commandId)
        let acceptedSeq = try store.getSnapshot().seq
        try store.discardJournal()
        let reopened = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        let client = WireSessionTestClient(service: .init(store: reopened))
        let session = BoardSession(client: client, storage: storage, key: "wire")
        let task = Task { await session.run() }; defer { task.cancel() }
        try await waitForSession { session.canSend }
        XCTAssertTrue(session.pendingRecords.isEmpty)
        XCTAssertEqual(session.journal?.records.first?.envelope, envelope)
        XCTAssertEqual(session.journal?.records.first?.reply, original)
        XCTAssertEqual(client.mutations, [envelope])
        XCTAssertEqual(try reopened.getSnapshot().seq, acceptedSeq, "Exact replay must not create another review decision")
        XCTAssertEqual(session.projection?.tasks["review-once"]?.state, .done)
        task.cancel(); await task.value
    }
}

extension ProcessControlTests {
    @MainActor func testCompletedWIPWithLostReplyReconcilesFromWireAfterRetention() async throws {
        let f = try fixture(), (run, clone, ref) = try savedWIP(f, id: "wire-restore")
        _ = try f.store.execute(.init(command: .pauseTask(taskId: "wire-restore")))
        let storage = MemoryKeyValueStore(), envelope = CommandEnvelope(command: .restoreWIP(taskId: "wire-restore", runId: run, wipRef: ref))
        let journal = try ClientCommandJournal(storage: storage, key: "wire")
        try journal.begin(envelope); _ = try f.store.execute(envelope); try journal.markUncertain(envelope.commandId)
        _ = try f.store.runWIPRestorePass(owner: "test", at: at)
        try "later user edit".write(toFile: clone.clonePath + "/draft.txt", atomically: true, encoding: .utf8)
        try f.store.discardJournal()
        let reopened = try KabanStore(path: f.path), client = WireSessionTestClient(service: .init(store: reopened))
        let seq = try reopened.getSnapshot().seq
        let session = BoardSession(client: client, storage: storage, key: "wire")
        let task = Task { await session.run() }; defer { task.cancel() }
        try await waitForSession { session.canSend }
        XCTAssertTrue(session.pendingRecords.isEmpty)
        XCTAssertEqual(session.journal?.records.first?.phase, .applied)
        XCTAssertEqual(client.mutations, [envelope])
        XCTAssertEqual(try reopened.getSnapshot().seq, seq)
        XCTAssertTrue(try reopened.runWIPRestorePass(owner: "test", at: at).isEmpty)
        XCTAssertEqual(try String(contentsOfFile: clone.clonePath + "/draft.txt", encoding: .utf8), "later user edit")
        task.cancel(); await task.value
    }
}

@MainActor private func waitForSession(_ condition: () -> Bool) async throws {
    for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
    XCTFail("Wire session did not connect"); throw CommandError(code: "test_timeout", message: "Session timeout")
}

/// Test bridge uses the real encoded DaemonService contract and session poller.
@MainActor private final class WireSessionTestClient: KabanClient {
    private let daemon: DaemonClient
    var mutations: [CommandEnvelope] = []
    init(service: DaemonService) { daemon = .init(transport: WireSessionTestTransport(service: service)) }
    func getSnapshot() async throws -> Snapshot { try await daemon.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await daemon.synchronize() }
    func capabilities() async throws -> DaemonCapabilities { try await daemon.capabilities() }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if envelope.command.mutationScope != nil { mutations.append(envelope) }
        return try await daemon.send(envelope)
    }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> {
        let source = daemon.sessionUpdates()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await update in source {
                        switch update {
                        case .connection(let state): continuation.yield(.connection(state))
                        case .replacement(let replacement): continuation.yield(.replacement(replacement))
                        case .event(let event): continuation.yield(.event(event))
                        case .ephemeral(let event): continuation.yield(.ephemeral(event))
                        case .snapshot: throw CommandError(code: "invalid_reply", message: "Expected full replacement")
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { $0.finish() } }
}
private struct WireSessionTestTransport: DaemonTransport {
    let service: DaemonService
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        try DaemonWire.decode(DaemonResponse.self, from: service.handle(data: DaemonWire.encode(request)))
    }
}
