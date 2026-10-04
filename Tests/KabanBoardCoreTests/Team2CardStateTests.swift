import XCTest
@testable import KabanBoardCore
import KabanProtocol

/// Plan 3.4 transport/projection coverage. BoardCore has no card renderer API.
final class Team2CardStateTests: XCTestCase {
    func testUncoveredReasonsSurviveSnapshotAndFullCardReplacement() {
        let rows: [TaskState] = [
            .queued(.quotaCm), .queued(.quotaOm), .queued(.modelFlag),
            .gating, .retryWait(.crash), .retryWait(.stallTimeout),
            .retryWait(.wallTimeout), .retryWait(.noFinalCall), .retryWait(.gateFailed),
            .retryWait(.rateLimit), .retryWait(.runnerAuth), .retryWait(.daemonRestart),
            .retryWait(.silentExit), .waitingHuman(.retriesExhausted),
            .waitingHuman(.runLimit), .waitingHuman(.modelSubstituted),
            .waitingHuman(.bounceLimit), .waitingHuman(.conflictLimit),
            .waitingHuman(.gitDenials), .waitingHuman(.invalidResult),
            .waitingHuman(.incident), .blocked(.mainDirty), .done, .cancelled,
        ]
        for (index, state) in rows.enumerated() {
            let id = "row-\(index)"
            let initial = Fix.card(id, stage: "test", state: state)
            var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [initial]))
            XCTAssertEqual(projection.tasks[initial.id]?.state, state, "snapshot: \(state)")
            var update = initial
            update.stageId = "dev"
            update.title = "changed"
            update.attempt = 2
            update.maxAttempts = 3
            update.retryAt = Fix.t0.addingTimeInterval(30)
            XCTAssertEqual(projection.apply(Fix.envelope(2, .taskUpdated(update))), .applied)
            XCTAssertEqual(projection.tasks[initial.id], update, "full replacement: \(state)")
            XCTAssertEqual(projection.lanes()[0].columns.first { $0.stage.id == "dev" }?.taskIds, [initial.id])
            XCTAssertEqual(projection.lanes()[0].columns.first { $0.stage.id == "test" }?.taskIds, [])
        }
    }

    func testLimitsAndBadgesRemainDaemonDataRatherThanBeingRecomputed() {
        var card = Fix.card("limits", state: .waitingHuman(.runLimit))
        card.attempt = 3
        card.maxAttempts = 3
        card.runsSinceHuman = 12
        card.bounceByReason = ["test->dev": 3, "merge->dev": 2]
        card.overlapsWith = ["other-a", "other-b"]
        card.unusedGitGrants = 2
        card.model = "explicit-model"
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [card]))
        XCTAssertEqual(projection.tasks[card.id], card)
        // A new complete daemon card resets counters; no stale local badges survive.
        let reset = Fix.card("limits", state: .queued(nil), hasAcceptanceCriteria: true)
        XCTAssertEqual(projection.apply(Fix.envelope(2, .taskUpdated(reset))), .applied)
        XCTAssertEqual(projection.tasks[card.id], reset)
        XCTAssertEqual(projection.tasks[card.id]?.runsSinceHuman, 0)
        XCTAssertEqual(projection.tasks[card.id]?.bounceByReason, [:])
        XCTAssertEqual(projection.tasks[card.id]?.unusedGitGrants, 0)
        XCTAssertEqual(projection.tasks[card.id]?.hasAcceptanceCriteria, true)
    }

    func testPatternAndSizeSuspiciousRowsSurviveResyncWithoutTruncation() {
        let files = [
            SuspiciousFile(path: ".env.local", rule: .pattern, pattern: ".env*", sizeBytes: 12, isText: true, blob: "a"),
            SuspiciousFile(path: "dump.sql", rule: .size, sizeBytes: 6_000_000, isText: true, blob: "b"),
            SuspiciousFile(path: "binary.key", rule: .pattern, pattern: "*.key", sizeBytes: 42, isText: false, blob: "c"),
        ]
        let card = Fix.card("suspicious", state: .waitingHuman(.suspiciousFiles), files: files)
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [card]))
        XCTAssertEqual(projection.tasks[card.id]?.suspiciousFiles, files)
        XCTAssertEqual(projection.apply(.resyncRequired), .resyncRequired)
        projection.replace(with: Fix.snapshot(seq: 40, tasks: [card]))
        XCTAssertEqual(projection.tasks[card.id]?.suspiciousFiles, files)
        XCTAssertEqual(projection.openIncidentCount, 0, "suspicious files are not incidents")
        let clear = Fix.card("suspicious", state: .queued(nil))
        XCTAssertEqual(projection.apply(Fix.envelope(41, .taskUpdated(clear))), .applied)
        XCTAssertTrue(projection.tasks[card.id]?.suspiciousFiles.isEmpty == true)
    }

    func testReadonlyFailureRemainsInItsDaemonSelectedStage() {
        let first = Fix.card("readonly", stage: "test", state: .retryWait(.readonlyViolation))
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [first]))
        var second = first
        second.state = .waitingHuman(.invalidResult)
        second.attempt = 2
        second.maxAttempts = 3
        XCTAssertEqual(projection.apply(Fix.envelope(2, .taskUpdated(second))), .applied)
        XCTAssertEqual(projection.tasks[first.id], second)
        XCTAssertEqual(projection.lanes()[0].columns.first { $0.stage.id == "test" }?.taskIds, [first.id])
        // This verifies display inputs, not daemon retry/rollback policy or action rendering.
    }
}
