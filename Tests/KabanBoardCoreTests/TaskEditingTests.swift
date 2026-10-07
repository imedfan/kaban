import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class TaskEditingTests: XCTestCase {
    @MainActor func testExactMarkdownAndUnknownBodyNeverBecomeEmpty() throws {
        let storage = MemoryKeyValueStore(), card = Fix.card("a")
        let drafts = try TaskDraftStore(storage: storage, key: "drafts")
        let body = "# Title\r\n\r\n**spaces**  \r\n~~~swift\r\nlet x = 1\r\n~~~\r\n\n## Критерии приёмки\n- [ ] exact\n"
        try drafts.save(.init(key: .edit(card.id), draft: .init(title: "Changed"), exactBody: body, baseCard: card))
        let reopened = try TaskDraftStore(storage: storage, key: "drafts")
        XCTAssertEqual(reopened.editCommand(for: .edit(card.id), current: card, bodyIsKnown: true),
                       .editTask(taskId: card.id, title: "Changed", body: body))
        XCTAssertEqual(reopened.editCommand(for: .edit(card.id), current: card, bodyIsKnown: false),
                       .editTask(taskId: card.id, title: "Changed", body: nil))
        XCTAssertEqual(reopened.record(for: .edit(card.id))?.exactBody, body)
    }
    @MainActor func testChangedRunningGatingAndMissingCardsKeepDraftUntilReviewed() throws {
        let drafts = try TaskDraftStore(storage: MemoryKeyValueStore(), key: "drafts")
        let original = Fix.card("a")
        try drafts.save(.init(key: .edit("a"), draft: .init(title: "My edit"), exactBody: "My text", baseCard: original))
        for current in [Fix.card("a", state: .running), Fix.card("a", state: .gating), Fix.card("a", title: "Other edit")] {
            XCTAssertNil(drafts.editCommand(for: .edit("a"), current: current, bodyIsKnown: true))
            XCTAssertEqual(drafts.record(for: .edit("a"))?.exactBody, "My text")
        }
        XCTAssertNil(drafts.editCommand(for: .edit("a"), current: nil, bodyIsKnown: true))
        var reviewed = drafts.record(for: .edit("a"))!
        reviewed.baseCard = Fix.card("a", title: "Other edit")
        try drafts.save(reviewed)
        XCTAssertEqual(drafts.editCommand(for: .edit("a"), current: reviewed.baseCard, bodyIsKnown: true),
                       .editTask(taskId: "a", title: "My edit", body: "My text"))
    }
    @MainActor func testDraftsInDifferentProjectsRemainSeparateAndPriorityInputSurvives() throws {
        let storage = MemoryKeyValueStore(), drafts = try TaskDraftStore(storage: storage, key: "drafts")
        try drafts.save(.init(key: .create(Fix.project), draft: .init(title: "First"), exactBody: "one\r\n"))
        try drafts.save(.init(key: .create(Fix.other), draft: .init(title: "Second"), exactBody: "two  \n"))
        try drafts.save(.init(key: .priority("a"), draft: .init(), priorityText: "-214"))
        let reopened = try TaskDraftStore(storage: storage, key: "drafts")
        XCTAssertEqual(reopened.record(for: .create(Fix.project))?.exactBody, "one\r\n")
        XCTAssertEqual(reopened.record(for: .create(Fix.other))?.exactBody, "two  \n")
        XCTAssertEqual(reopened.record(for: .priority("a"))?.priorityText, "-214")
    }
    @MainActor func testUnknownBodyRejectionIsAtomicAndTitleOnlyStillWorks() async throws {
        let card = Fix.card("a"), client = MockKabanClient(snapshot: Fix.snapshot(tasks: [card]))
        let rejected = try await client.send(.init(command: .editTask(taskId: "a", title: "Changed", body: "")))
        guard case .error = rejected.result else { return XCTFail("Unknown body must be rejected") }
        let unchanged = try await client.getSnapshot()
        XCTAssertEqual(unchanged.tasks.first, card)
        let titleOnly = try await client.send(.init(command: .editTask(taskId: "a", title: "Changed", body: nil)))
        XCTAssertEqual(titleOnly.result, .ok)
        let detail = try await client.send(.init(command: .getTaskDetail(taskId: "a")))
        guard case .taskDetail(let value) = detail.result else { return XCTFail("Missing details") }
        XCTAssertNil(value.body); XCTAssertEqual(value.task.title, "Changed")
    }
    @MainActor func testReceiverRefusesRaceToRunningOrGatingWithoutDiscardingSubmittedDraft() async throws {
        for state in [TaskState.running, .gating] {
            let storage = MemoryKeyValueStore()
            let session = BoardSession(client: MockKabanClient(snapshot: Fix.snapshot(tasks: [Fix.card("a", state: state)])), storage: storage, key: "race")
            let task = Task { await session.run() }
            for _ in 0..<400 { if session.canSend { break }; try await Task.sleep(for: .milliseconds(5)) }
            try session.drafts?.save(.init(key: .edit("a"), draft: .init(title: "My title"), exactBody: "My exact  \r\n", baseCard: Fix.card("a")))
            let applied = await session.send(.editTask(taskId: "a", title: "My title", body: "My exact  \r\n"), editor: true)
            XCTAssertFalse(applied); XCTAssertNotNil(session.editorError)
            XCTAssertEqual(session.projection?.tasks["a"]?.state, state)
            let restored = try TaskDraftStore(storage: storage, key: "race.drafts")
            XCTAssertEqual(restored.record(for: .edit("a"))?.exactBody, "My exact  \r\n")
            task.cancel(); await task.value
        }
    }
    @MainActor func testPriorityUsesCorrelatedUpdateAndExactReplayWithoutChangingState() async throws {
        var card = Fix.card("a", state: .running); card.priority = 17
        let client = MockKabanClient(snapshot: Fix.snapshot(tasks: [card]))
        let capabilities = try await client.capabilities()
        XCTAssertTrue(capabilities.supports(.setPriority))
        let envelope = CommandEnvelope(command: .setPriority(taskId: card.id, priority: -4))
        let reply = try await client.send(envelope)
        XCTAssertEqual(reply.result, .ok)
        let changed = try await client.getSnapshot()
        XCTAssertEqual(changed.tasks[0].priority, -4); XCTAssertEqual(changed.tasks[0].state, .running)
        let replay = try await client.send(envelope)
        XCTAssertEqual(replay, reply)
        let replayed = try await client.getSnapshot()
        XCTAssertEqual(replayed.seq, changed.seq)
        for state in [TaskState.done, .cancelled] {
            let terminal = MockKabanClient(snapshot: Fix.snapshot(tasks: [Fix.card("done", state: state)]))
            let refusal = try await terminal.send(.init(command: .setPriority(taskId: "done", priority: 10)))
            guard case .error = refusal.result else { return XCTFail("Terminal priority must be rejected") }
        }
    }
    @MainActor func testPriorityConfirmationClearsOnlyItsSubmittedDraft() async throws {
        let session = BoardSession(client: MockKabanClient(snapshot: Fix.snapshot(tasks: [Fix.card("a")])),
                                   storage: MemoryKeyValueStore(), key: "test")
        let task = Task { await session.run() }; defer { task.cancel() }
        for _ in 0..<400 { if session.canSend { break }; try await Task.sleep(for: .milliseconds(5)) }
        try session.drafts?.save(.init(key: .priority("a"), draft: .init(), priorityText: "42"))
        try session.drafts?.save(.init(key: .edit("a"), draft: .init(title: "Unsent"), exactBody: "Unsent body"))
        let sent = await session.send(.setPriority(taskId: "a", priority: 42))
        XCTAssertTrue(sent)
        for _ in 0..<400 { if session.pendingRecords.isEmpty && session.canSend { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.projection?.tasks["a"]?.priority, 42)
        XCTAssertNil(session.drafts?.record(for: .priority("a")))
        XCTAssertEqual(session.drafts?.record(for: .edit("a"))?.exactBody, "Unsent body")
    }
}
