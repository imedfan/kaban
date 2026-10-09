import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class AttentionTests: XCTestCase {
    @MainActor func testBaselineReplayAndRebootDoNotNotifyAgain() {
        let storage = MemoryKeyValueStore(), now = Fix.t0
        var card = Fix.card("a", state: .waitingHuman(.review))
        var board = BoardProjection(snapshot: Fix.snapshot(tasks: [card]))
        let store = AttentionStore(storage: storage, key: "notices")
        XCTAssertTrue(store.receive(.replacement, board: board, now: now).isEmpty)
        card.title = "Изменённый заголовок"
        let edited = Fix.envelope(11, .taskEdited(card)); _ = board.apply(edited)
        XCTAssertTrue(store.receive(.journal(edited), board: board, now: now).isEmpty)
        card.state = .queued(nil)
        let leave = Fix.envelope(12, .taskUpdated(card)); _ = board.apply(leave)
        XCTAssertTrue(store.receive(.journal(leave), board: board, now: now).isEmpty)
        card.state = .waitingHuman(.review)
        let enter = Fix.envelope(13, .taskUpdated(card)); _ = board.apply(enter)
        XCTAssertEqual(store.receive(.journal(enter), board: board, now: now).count, 1)
        XCTAssertTrue(store.receive(.journal(enter), board: board, now: now).isEmpty)
        let reopened = AttentionStore(storage: storage, key: "notices")
        XCTAssertTrue(reopened.receive(.replacement, board: board, now: now).isEmpty)
        XCTAssertTrue(reopened.receive(.journal(enter), board: board, now: now).isEmpty)
    }
    @MainActor func testQuestionBeforeCardHasOneExactReplyTarget() {
        let store = AttentionStore(storage: MemoryKeyValueStore(), key: "questions")
        var card = Fix.card("a")
        var board = BoardProjection(snapshot: Fix.snapshot(tasks: [card])); _ = store.receive(.replacement, board: board, now: Fix.t0)
        let request = HumanRequest(requestId: "question-1", taskId: "a", runId: "r", question: "Какой вариант?")
        let question = Fix.envelope(11, .humanRequested(request)); _ = board.apply(question)
        XCTAssertTrue(store.receive(.journal(question), board: board, now: Fix.t0).isEmpty)
        card.state = .waitingHuman(.question)
        let waiting = Fix.envelope(12, .taskUpdated(card)); _ = board.apply(waiting)
        let notices = store.receive(.journal(waiting), board: board, now: Fix.t0)
        XCTAssertEqual(notices.count, 1); XCTAssertTrue(notices.first?.canReply == true)
        XCTAssertEqual(notices.first?.target, .task(projectID: Fix.project, taskID: "a", requestID: "question-1"))
        XCTAssertTrue(store.receive(.journal(waiting), board: board, now: Fix.t0).isEmpty)
    }
    @MainActor func testReplacementBetweenQuestionAndCardPreservesFreshNotice() {
        let store = AttentionStore(storage: MemoryKeyValueStore(), key: "replacement")
        var card = Fix.card("a")
        var board = BoardProjection(snapshot: Fix.snapshot(tasks: [card])); _ = store.receive(.replacement, board: board, now: Fix.t0)
        let request = Fix.envelope(11, .humanRequested(.init(requestId: "fresh", taskId: "a", runId: "r", question: "Вопрос")))
        _ = board.apply(request); XCTAssertTrue(store.receive(.journal(request), board: board, now: Fix.t0).isEmpty)
        card.state = .waitingHuman(.question)
        board = BoardProjection(snapshot: Fix.snapshot(seq: 12, tasks: [card]))
        XCTAssertEqual(store.receive(.replacement, board: board, now: Fix.t0).first?.target,
                       .task(projectID: Fix.project, taskID: "a", requestID: "fresh"))
        XCTAssertTrue(store.receive(.replacement, board: board, now: Fix.t0).isEmpty)
    }
    @MainActor func testOldCatchupDisabledAndGlobalFlagsDoNotFlood() {
        let storage = MemoryKeyValueStore(), store = AttentionStore(storage: storage, key: "flags")
        var board = BoardProjection(snapshot: Fix.snapshot()); _ = store.receive(.replacement, board: board, now: Fix.t0)
        let cursor = EphemeralCursor(sessionId: UUID(), offset: 1)
        let flag = EphemeralEnvelope(cursor: cursor, afterSeq: 10, at: Fix.t0, event: .schedulerFlagsChanged([.runnerUnavailable(.runnerAuth)]))
        _ = board.apply(flag.event)
        XCTAssertEqual(store.receive(.ephemeral(flag), board: board, now: Fix.t0).count, 1)
        XCTAssertTrue(store.receive(.ephemeral(flag), board: board, now: Fix.t0).isEmpty)
        for seq: Seq in 11...13 {
            let task = Fix.envelope(seq, .taskCreated(Fix.card("queued-\(seq)", state: .queued(nil))))
            _ = board.apply(task)
            XCTAssertTrue(store.receive(.journal(task), board: board, now: Fix.t0).isEmpty)
        }
        store.setEnabled(false)
        XCTAssertFalse(AttentionStore(storage: storage, key: "flags").enabled)
        let question = Fix.envelope(14, .incidentOpened(.init(id: "incident", projectId: Fix.project, taskId: "a", runId: nil, kind: .refsMoved, rolledBack: [], openedAt: Fix.t0)))
        _ = board.apply(question); XCTAssertTrue(store.receive(.journal(question), board: board, now: Fix.t0).isEmpty)
        store.setEnabled(true); XCTAssertTrue(store.receive(.journal(question), board: board, now: Fix.t0).isEmpty)
        let incident = Fix.envelope(15, .incidentOpened(.init(id: "fresh", projectId: Fix.project, taskId: "a", runId: nil, kind: .refsMoved, rolledBack: [], openedAt: Fix.t0)))
        _ = board.apply(incident)
        let notices = store.receive(.journal(incident), board: board, now: Fix.t0)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.timeSensitive == true)
        XCTAssertEqual(notices.first?.target, .incident(projectID: Fix.project, taskID: "a", incidentID: "fresh"))
        let old = Fix.envelope(16, .taskCreated(Fix.card("old", state: .waitingHuman(.review))))
        _ = board.apply(old); XCTAssertTrue(store.receive(.journal(old), board: board, now: Fix.t0.addingTimeInterval(601)).isEmpty)
        XCTAssertTrue(AttentionStore(storage: storage, key: "flags").enabled)
    }
    @MainActor func testSessionPublishesOnlyAppliedAndDrainedUpdates() throws {
        let session = BoardSession(client: MockKabanClient(snapshot: Fix.snapshot()), storage: MemoryKeyValueStore(), key: "session")
        let sessionID = UUID()
        var observed: [BoardSessionUpdate] = []
        session.onAppliedUpdate = { observed.append($0) }
        try session.consume(.replacement(.init(snapshot: Fix.snapshot(), cursor: .init(sessionId: sessionID, offset: 0), current: [])))
        let future = EphemeralEnvelope(cursor: .init(sessionId: sessionID, offset: 1), afterSeq: 11, at: Fix.t0, event: .schedulerFlagsChanged([.runnerUnavailable(.runnerAuth)]))
        try session.consume(.ephemeral(future)); XCTAssertEqual(observed.count, 1)
        let event = Fix.envelope(11, .taskCreated(Fix.card("a")))
        try session.consume(.event(event)); XCTAssertEqual(observed.count, 3)
        try session.consume(.event(event)); XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(session.projection?.ephemeral.schedulerFlags, [.runnerUnavailable(.runnerAuth)])
    }
}
