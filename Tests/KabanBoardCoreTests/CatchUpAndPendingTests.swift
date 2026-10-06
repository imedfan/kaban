import XCTest
@testable import KabanBoardCore
import KabanProtocol

final class CatchUpTests: XCTestCase {
    func testDuplicatesAreDroppedAndGapsRequestResync() {
        let original = Fix.card("t-1", title: "Было")
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 10, tasks: [original]))
        let updated = Fix.card("t-1", state: .running, title: "Стало")
        XCTAssertEqual(projection.apply(Fix.envelope(11, .taskUpdated(updated))), .applied)
        XCTAssertEqual(projection.apply(Fix.envelope(11, .taskUpdated(Fix.card("t-1", title: "Дубль")))), .duplicate)
        XCTAssertEqual(projection.apply(Fix.envelope(10, .taskUpdated(Fix.card("t-1", title: "Старый seq")))), .duplicate)
        XCTAssertEqual(projection.tasks["t-1"], updated)

        XCTAssertEqual(projection.apply(Fix.envelope(13, .taskUpdated(Fix.card("t-1", title: "Дырка")))), .gap(expected: 12, received: 13))
        XCTAssertTrue(projection.needsResync)
        XCTAssertEqual(projection.tasks["t-1"], updated)
        XCTAssertEqual(projection.stateSeq, 11)
        XCTAssertEqual(projection.apply(Fix.envelope(12, .taskUpdated(Fix.card("t-1", title: "После дырки")))), .needsResync)
        XCTAssertEqual(projection.tasks["t-1"]?.title, "Стало")
    }

    func testResyncRequiredReplacesStateFromSnapshot() throws {
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 4, tasks: [Fix.card("t-1", title: "Старая")]))
        projection.markSent(commandId: Fix.command, taskId: "t-1", at: Fix.t0)
        let quota = QuotaState(cm: 10, om: nil, billingCycleEnd: nil, fetchedAt: Fix.t0)
        XCTAssertEqual(projection.apply(.quotaUpdated(quota)), .applied)
        XCTAssertEqual(projection.apply(.resyncRequired), .resyncRequired)
        XCTAssertTrue(projection.needsResync)
        XCTAssertEqual(projection.tasks["t-1"]?.title, "Старая")
        XCTAssertEqual(projection.ephemeral.quota, quota)
        XCTAssertEqual(projection.stateSeq, 4)

        let fresh = Fix.card("t-9", stage: "backlog", state: .queued(.wipFull), title: "Из снимка")
        let snapshot = Fix.snapshot(seq: 40, tasks: [fresh], openIncidents: 0)
        projection.replace(with: snapshot)
        XCTAssertFalse(projection.needsResync)
        XCTAssertEqual(projection.stateSeq, 40)
        XCTAssertNil(projection.tasks["t-1"])
        XCTAssertEqual(projection.tasks["t-9"], fresh)
        XCTAssertNil(projection.ephemeral.quota, "эфемерное берётся заново из снимка")
        XCTAssertTrue(projection.isSent("t-1"), "ожидание команды переживает замену снимка")
        XCTAssertEqual(try XCTUnwrap(projection.cursor(for: .all)).lastAppliedSeq, 40)

        let done = Fix.card("t-9", stage: "backlog", state: .queued(nil), title: "После догонки")
        XCTAssertEqual(projection.apply(Fix.envelope(41, .taskUpdated(done), commandId: Fix.command)), .applied)
        XCTAssertEqual(projection.tasks["t-9"], done)
        XCTAssertTrue(projection.isSent("t-1"), "Another resource cannot resolve this task intent")
        projection.noteCommandError(Fix.command)
        XCTAssertFalse(projection.isSent("t-1"))
    }

    func testEphemeralEventsDoNotTouchCardsOrSeq() {
        let card = Fix.card("t-1", state: .running)
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 8, tasks: [card]))
        let before = projection
        XCTAssertEqual(projection.apply(.schedulerFlagsChanged([.macPaused])), .applied)
        XCTAssertEqual(projection.apply(.modelFlagsChanged([
            ModelFlag(modelId: "composer-2", reason: .unavailable, requested: "Composer", since: Fix.t0),
        ])), .applied)
        XCTAssertEqual(projection.apply(.modelCatalogChanged([
            ModelInfo(id: "composer-2", name: "Composer", pool: .cm),
        ])), .applied)
        XCTAssertEqual(projection.apply(.runnerChecked(RunnerCheck(ok: false, reason: .runnerAuth, checkedAt: Fix.t0))), .applied)
        XCTAssertEqual(projection.apply(.runProgress(RunProgress(runId: "r-1", taskId: "t-1", message: "тест", lastActivityAt: Fix.t0))), .applied)
        XCTAssertEqual(projection.apply(.unknown(type: "liveSomething")), .ignored)
        XCTAssertEqual(projection.tasks, before.tasks)
        XCTAssertEqual(projection.stateSeq, before.stateSeq)
        XCTAssertEqual(projection.cursor(for: .all), before.cursor(for: .all))
        XCTAssertEqual(projection.feed, before.feed)
        XCTAssertEqual(projection.ephemeral.schedulerFlags, [.macPaused])
        XCTAssertEqual(projection.ephemeral.runProgress["r-1"]?.message, "тест" as String?)
        XCTAssertEqual(projection.ephemeral.runnerCheck?.reason, .runnerAuth as RunnerUnavailableReason?)
    }
}

final class PendingCommandTests: XCTestCase {
    func testTaskUpdatedWithMatchingCommandIdClearsSent() {
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [Fix.card("t-1")]))
        projection.markSent(commandId: Fix.command, taskId: "t-1", at: Fix.t0)
        let other = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
        XCTAssertEqual(projection.apply(Fix.envelope(2, .taskUpdated(Fix.card("t-1", state: .paused)), commandId: other)), .applied)
        XCTAssertTrue(projection.isSent("t-1"))
        XCTAssertEqual(projection.apply(Fix.envelope(3, .taskUpdated(Fix.card("t-1", state: .queued(nil))))), .applied)
        XCTAssertTrue(projection.isSent("t-1"), "без commandId метка остаётся")
        XCTAssertEqual(
            projection.apply(Fix.envelope(4, .taskUpdated(Fix.card("t-1", state: .queued(nil), title: "Готово")), commandId: Fix.command)),
            .applied
        )
        XCTAssertFalse(projection.isSent("t-1"))
        XCTAssertEqual(projection.tasks["t-1"]?.title, "Готово")
    }

    func testCommandErrorClearsSentWithoutChangingTheCard() {
        let card = Fix.card("t-1", state: .waitingHuman(.suspiciousFiles), files: [Fix.file(".env.local", blob: "ffff01")])
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [card]))
        projection.markSent(commandId: Fix.command, taskId: "t-1", at: Fix.t0)
        projection.noteCommandError(Fix.command)
        XCTAssertFalse(projection.isSent("t-1"))
        XCTAssertEqual(projection.tasks["t-1"], card)
        XCTAssertEqual(projection.stateSeq, 1)
    }
}
