import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class BoardSessionTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Session did not reach expected state"); throw CommandError(code: "test_timeout", message: "State timeout")
    }
    @MainActor func testLostCreationReopensWithExactReplayAndRetentionSnapshot() async throws {
        let storage = MemoryKeyValueStore(), client = SessionFaultClient()
        let envelope = CommandEnvelope(command: .createTask(projectId: Fix.project, title: "Exact\r\n", body: "**keep**  \n"))
        let journal = try ClientCommandJournal(storage: storage, key: "test")
        try journal.begin(envelope); try journal.markUncertain(envelope.commandId)
        client.receipt = .init(commandId: envelope.commandId, seq: 11, result: .taskCreated("created"))
        client.snapshot = Fix.snapshot(seq: 11, tasks: [Fix.card("created")])
        let session = BoardSession(client: client, storage: storage, key: "test")
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }
        XCTAssertEqual(client.mutations, [envelope])
        XCTAssertEqual(session.createdTaskID, "created"); XCTAssertNil(session.creation.commandID)
        XCTAssertTrue(session.pendingRecords.isEmpty)
        XCTAssertEqual(session.projection?.tasks.count, 1)
        task.cancel(); await task.value
        try await wait { client.terminations == 1 }
        XCTAssertEqual(client.subscriptions, 1)
    }
    @MainActor func testEventBeforeReplyAndDuplicateDoNotKeepTaskSent() async throws {
        let client = SessionFaultClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        client.snapshot = Fix.snapshot(tasks: [Fix.card("t")])
        client.mutationHandler = { envelope in
            let event = Fix.envelope(11, .taskEdited(Fix.card("t", title: "Edited")), commandId: envelope.commandId)
            client.snapshot = Fix.snapshot(seq: 11, tasks: [Fix.card("t", title: "Edited")])
            client.continuation?.yield(.event(event)); client.continuation?.yield(.event(event))
            for _ in 0..<10 { await Task.yield() }
            throw CommandError(code: "connection_lost", message: "Reply lost after commit")
        }
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }
        let applied = await session.send(.editTask(taskId: "t", title: "Edited", body: nil))
        XCTAssertTrue(applied, "A correlated event already proves application despite a lost reply")
        try await wait { session.canSend && session.pendingRecords.isEmpty }
        XCTAssertEqual(client.mutations.count, 1)
        XCTAssertFalse(session.projection!.isSent("t")); XCTAssertEqual(session.projection?.tasks["t"]?.title, "Edited")
    }
    @MainActor func testGapAndOverflowRecreateOneStreamAndClearVolatileFlags() async throws {
        let client = SessionFaultClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        client.snapshot.schedulerFlags = [.macPaused]
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }
        client.snapshot = Fix.snapshot(seq: 20, tasks: [Fix.card("after-gap")])
        client.cursor = .init(sessionId: UUID(), offset: 0)
        client.continuation?.yield(.event(Fix.envelope(15, .taskUpdated(Fix.card("gap")))))
        try await wait { session.canSend && session.recoveryCount == 1 }
        XCTAssertEqual(session.projection?.tasks.keys.map(\.rawValue).sorted(), ["after-gap"])
        XCTAssertEqual(session.projection?.ephemeral.schedulerFlags, [])
        client.snapshot = Fix.snapshot(seq: 30, tasks: [Fix.card("after-overflow")])
        client.continuation?.finish(throwing: CommandError(code: "buffer_overflow", message: "Buffer full"))
        try await wait { session.canSend && session.recoveryCount == 2 }
        XCTAssertEqual(client.subscriptions, 3)
        XCTAssertEqual(session.projection?.tasks.keys.map(\.rawValue).sorted(), ["after-overflow"])
        task.cancel(); await task.value
        try await wait { client.terminations == 3 }
    }
    @MainActor func testEphemeralBarrierCursorsAndStaleFlagsAreIndependentOfJournal() async throws {
        let client = SessionFaultClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }
        let live = EphemeralEnvelope(cursor: .init(sessionId: client.cursor.sessionId, offset: 1), afterSeq: 11, at: Fix.t0, event: .schedulerFlagsChanged([.macPaused]))
        try session.consume(.ephemeral(live))
        XCTAssertEqual(session.receivedEphemeralCursor?.offset, 1); XCTAssertEqual(session.ephemeralCursor?.offset, 0)
        XCTAssertEqual(session.projection?.stateSeq, 10); XCTAssertEqual(session.projection?.ephemeral.schedulerFlags, [])
        try session.consume(.event(Fix.envelope(11, .settingsChanged(.init(key: "scheduler", value: "updated", schedulerFlags: [])))))
        XCTAssertEqual(session.ephemeralCursor?.offset, 1)
        try session.consume(.event(Fix.envelope(12, .settingsChanged(.init(key: "scheduler", value: "updated", schedulerFlags: [])))))
        try session.consume(.ephemeral(.init(cursor: .init(sessionId: client.cursor.sessionId, offset: 2), afterSeq: 11, at: Fix.t0, event: .schedulerFlagsChanged([.macPaused]))))
        XCTAssertEqual(session.projection?.ephemeral.schedulerFlags, [])
        XCTAssertEqual(session.projection?.stateSeq, 12)
        var staleSnapshot = client.snapshot; staleSnapshot.seq = 12; staleSnapshot.schedulerFlags = [.macPaused]
        try session.consume(.replacement(.init(snapshot: staleSnapshot, cursor: client.cursor, current: [])))
        XCTAssertEqual(session.ephemeralCursor?.offset, 2, "Queued older replacement must not roll volatile state backwards")
        XCTAssertEqual(session.projection?.ephemeral.schedulerFlags, [])
        XCTAssertThrowsError(try session.consume(.ephemeral(.init(cursor: .init(sessionId: UUID(), offset: 1), afterSeq: 12, at: Fix.t0, event: .schedulerFlagsChanged([])))))
        try session.consume(.ephemeral(.init(cursor: .init(sessionId: client.cursor.sessionId, offset: 4), afterSeq: 12, at: Fix.t0, event: .schedulerFlagsChanged([]))))
        XCTAssertEqual(session.ephemeralCursor?.offset, 4, "Adapter may filter stale flags between delivered offsets; wire contiguity is checked by DaemonClient")
    }
    @MainActor func testStaleDetailCannotReplaceNewSelectionOrNewerSameTaskRead() async throws {
        let client = SessionFaultClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        client.snapshot = Fix.snapshot(tasks: [Fix.card("a"), Fix.card("b")]); client.holdDetails = true
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }
        let a = Task { await session.select("a") }
        try await wait { client.details.count == 1 }
        let b = Task { await session.select("b") }
        try await wait { client.details.count == 2 }
        client.completeDetail(1, task: "b", seq: 10, body: "new selection"); await b.value
        client.completeDetail(0, task: "a", seq: 10, body: "old selection"); await a.value
        XCTAssertEqual(session.detail?.task.id, "b")
        let oldB = Task { await session.select("b") }
        try await wait { client.details.count == 3 }
        try session.consume(.event(Fix.envelope(11, .taskUpdated(Fix.card("b", title: "Newer")))))
        try await wait { client.details.count == 4 }
        client.completeDetail(3, task: "b", seq: 11, body: "fresh")
        try await wait { session.detail?.body == "fresh" }
        client.completeDetail(2, task: "b", seq: 10, body: "stale"); await oldB.value
        XCTAssertEqual(session.detail?.body, "fresh")
    }
    @MainActor func testReconnectBlocksActionsAndKeepsSelectionAndDraftWhileVolatileStateResets() async throws {
        let client = SessionFaultClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        client.snapshot = Fix.snapshot(tasks: [Fix.card("a")]); client.snapshot.schedulerFlags = [.macPaused]
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }
        await session.select("a")
        try session.drafts?.save(.init(key: .edit("a"), draft: .init(title: "Saved"), exactBody: "**exact**  \r\n", baseCard: Fix.card("a")))
        try session.consume(.ephemeral(.init(cursor: .init(sessionId: client.cursor.sessionId, offset: 1), afterSeq: 10, at: Fix.t0, event: .runnerChecked(.init(ok: false, reason: .runnerAuth, checkedAt: Fix.t0)))))
        try session.consume(.connection(.reconnecting(lastSeq: 10)))
        XCTAssertFalse(session.canSend)
        let denied = await session.send(.pauseTask(taskId: "a")); XCTAssertFalse(denied); XCTAssertTrue(client.mutations.isEmpty)
        try session.consume(.connection(.synchronizing)); XCTAssertFalse(session.canSend)
        client.snapshot = Fix.snapshot(seq: 20, tasks: [Fix.card("a", title: "New server title")]); client.cursor = .init(sessionId: UUID(), offset: 0)
        try session.consume(.replacement(.init(snapshot: client.snapshot, cursor: client.cursor, current: [])))
        XCTAssertEqual(session.selectedID, "a")
        XCTAssertEqual(session.projection?.ephemeral.schedulerFlags, []); XCTAssertNil(session.projection?.ephemeral.runnerCheck)
        XCTAssertEqual(session.drafts?.record(for: .edit("a"))?.exactBody, "**exact**  \r\n")
        try session.consume(.connection(.connected))
        try await wait { session.canSend && session.detail?.seq == 20 }
        XCTAssertTrue(client.mutations.isEmpty, "Reconnection never submits user input")
    }
    @MainActor func testUnsupportedPendingAndCorruptStorageStayExplicitAndPreserved() async throws {
        let storage = MemoryKeyValueStore(), client = SessionFaultClient()
        let envelope = CommandEnvelope(command: .restoreWIP(taskId: "a", runId: "r", wipRef: "ref"))
        let journal = try ClientCommandJournal(storage: storage, key: "test")
        try journal.begin(envelope); try journal.markUncertain(envelope.commandId)
        client.unsupported = [.restoreWIP]
        let session = BoardSession(client: client, storage: storage, key: "test")
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { if case .disconnected = session.connectionState { return true }; return false }
        XCTAssertEqual(session.journal?.records[0].envelope, envelope)
        XCTAssertEqual(session.journal?.records[0].phase, .deliveryUncertain)
        XCTAssertTrue(client.mutations.isEmpty)
        storage.set(Data("corrupt".utf8), forKey: "bad")
        let corrupt = BoardSession(client: client, storage: storage, key: "bad")
        await corrupt.run(); XCTAssertFalse(corrupt.canSend)
        if case .disconnected(let error) = corrupt.connectionState { XCTAssertEqual(error.code, "client_storage_invalid") }
        else { XCTFail("Corruption must not look like an endless connection") }
        XCTAssertEqual(storage.data(forKey: "bad"), Data("corrupt".utf8))
    }
    @MainActor func testDraftsStaySeparateFromCommandsAndLateConfirmationKeepsNewInput() async throws {
        let storage = MemoryKeyValueStore(), drafts = try TaskDraftStore(storage: storage, key: "drafts")
        let draft = DemoTaskDraft(title: "Exact", description: "\r\n`keep`  ", acceptanceCriteria: "- criterion")
        try drafts.save(.init(key: .create(Fix.project), draft: draft))
        let old = UUID(); try drafts.submitted(.create(Fix.project), by: old)
        try drafts.save(.init(key: .create(Fix.project), draft: .init(title: "New")))
        try drafts.confirmed(old)
        XCTAssertEqual(try TaskDraftStore(storage: storage, key: "drafts").record(for: .create(Fix.project))?.draft.title, "New")
        try drafts.save(.init(key: .edit("a"), draft: draft, exactBody: nil, baseCard: Fix.card("a")))
        XCTAssertNil(try TaskDraftStore(storage: storage, key: "drafts").record(for: .edit("a"))?.exactBody)
        XCTAssertEqual(try TaskDraftStore(storage: storage, key: "other-source").records, [])
    }
    @MainActor func testTitleOnlyConfirmationDoesNotDiscardAnUnsentBodyDraft() async throws {
        let session = BoardSession(client: MockKabanClient(snapshot: Fix.snapshot(tasks: [Fix.card("a")])), storage: MemoryKeyValueStore(), key: "test")
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }
        try session.drafts?.save(.init(key: .edit("a"), draft: .init(title: "Edited"), exactBody: "Unsent body", baseCard: Fix.card("a")))
        let sent = await session.send(.editTask(taskId: "a", title: "Edited", body: nil))
        XCTAssertTrue(sent)
        try await wait { session.canSend && session.pendingRecords.isEmpty }
        XCTAssertEqual(session.projection?.tasks["a"]?.title, "Edited")
        XCTAssertEqual(session.drafts?.record(for: .edit("a"))?.exactBody, "Unsent body")
    }
    @MainActor func testRestoreFailureRequiresExactIntentAndTerminalDetailBarrier() async throws {
        let journal = try ClientCommandJournal(storage: MemoryKeyValueStore(), key: "test")
        let envelope = CommandEnvelope(command: .restoreWIP(taskId: "a", runId: "r", wipRef: "ref")); try journal.begin(envelope)
        try journal.receive(.init(commandId: envelope.commandId, seq: 10, result: .ok))
        var detail = TaskDetail(seq: 11, task: Fix.card("a"), feed: [], runs: [], suspiciousFiles: [], acceptedFiles: [], wipRestoreOperations: [.init(commandId: envelope.commandId, runId: "r", wipRef: "ref", status: .failed, completedSeq: 12, message: "Failed")])
        try journal.observeRestores(in: detail); XCTAssertTrue(journal.records[0].isPending)
        detail.seq = 12; detail.task = Fix.card("other"); try journal.observeRestores(in: detail)
        XCTAssertTrue(journal.records[0].isPending)
        detail.task = Fix.card("a"); try journal.observeRestores(in: detail)
        XCTAssertEqual(journal.records[0].phase, .effectFailed(.init(code: "wip_restore_failed", message: "Failed")))
        XCTAssertFalse(journal.records[0].isPending)
    }
}

@MainActor private final class SessionFaultClient: KabanClient {
    var snapshot = Fix.snapshot()
    var cursor = EphemeralCursor(sessionId: UUID(), offset: 0)
    var continuation: AsyncThrowingStream<KabanClientUpdate, Error>.Continuation?
    var subscriptions = 0, terminations = 0
    var mutations: [CommandEnvelope] = []
    var receipt: CommandReply?
    var mutationHandler: ((CommandEnvelope) async throws -> CommandReply)?
    var unsupported: Set<CommandName> = []
    var holdDetails = false
    var details: [(CommandEnvelope, CheckedContinuation<CommandReply, Error>)] = []
    func getSnapshot() async throws -> Snapshot { snapshot }
    func synchronize() async throws -> SnapshotReplacement { .init(snapshot: snapshot, cursor: cursor, current: []) }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: ["synchronize"].map { .init(name: $0, supported: true) }, commands: CommandName.allCases.map { .init(name: $0.rawValue, support: unsupported.contains($0) ? .unsupported : .supported) })
    }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> {
        subscriptions += 1
        return AsyncThrowingStream { continuation in
            self.continuation = continuation; continuation.yield(.connection(.connected))
            continuation.onTermination = { @Sendable [weak self] _ in Task { @MainActor in self?.terminations += 1 } }
        }
    }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { $0.finish() } }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if case .getTaskDetail(let id) = envelope.command {
            if holdDetails { return try await withCheckedThrowingContinuation { details.append((envelope, $0)) } }
            return .init(commandId: envelope.commandId, seq: nil, result: .taskDetail(.init(seq: snapshot.seq, task: snapshot.tasks.first { $0.id == id } ?? Fix.card(id.rawValue), feed: [], runs: [], suspiciousFiles: [], acceptedFiles: [], body: "body", wipRestoreOperations: [])))
        }
        mutations.append(envelope)
        if let mutationHandler { return try await mutationHandler(envelope) }
        return receipt ?? .init(commandId: envelope.commandId, seq: snapshot.seq, result: .ok)
    }
    func completeDetail(_ index: Int, task: TaskID, seq: Seq, body: String) {
        let (envelope, continuation) = details[index]
        continuation.resume(returning: .init(commandId: envelope.commandId, seq: nil, result: .taskDetail(.init(seq: seq, task: Fix.card(task.rawValue), feed: [], runs: [], suspiciousFiles: [], acceptedFiles: [], body: body))))
    }
}
