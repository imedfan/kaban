import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class WIPRestoreRequestTests: XCTestCase {
    private func fixtureRun(_ task: TaskID = "task", ref: String? = "refs/kaban/wip/run") -> RunSummary {
        .init(id: "run", taskId: task, stageId: "dev", number: 1, status: .failed, endReason: .gateFailed,
              requestedModel: "model", startedAt: Fix.t0, wipRef: ref)
    }
    func testConfirmationUsesOnlyAnExactHistoryRunAndRef() {
        let card = Fix.card("task", state: .paused), source = fixtureRun(), pipeline = Fix.pipeline()
        let request = WIPRestoreRequest(card: card, run: source, pipeline: pipeline)
        XCTAssertEqual(request.command(current: card, history: [source], pipeline: pipeline),
                       .restoreWIP(taskId: "task", runId: "run", wipRef: "refs/kaban/wip/run"))
        XCTAssertNil(request.command(current: card, history: [], pipeline: pipeline))
        var changedRef = source; changedRef.wipRef = "refs/kaban/wip/other"
        XCTAssertNil(request.command(current: card, history: [changedRef], pipeline: pipeline))
        var changedRun = source; changedRun.id = "other"
        XCTAssertNil(request.command(current: card, history: [changedRun], pipeline: pipeline))
        XCTAssertEqual(source.wipRef, "refs/kaban/wip/run", "Confirmation never rewrites a historical run")
    }
    func testChangedTaskOrPipelineRequiresFreshConfirmation() {
        let card = Fix.card("task"), source = fixtureRun(), pipeline = Fix.pipeline()
        let request = WIPRestoreRequest(card: card, run: source, pipeline: pipeline)
        var current = card; current.priority += 1
        XCTAssertNil(request.command(current: current, history: [source], pipeline: pipeline))
        var changed = pipeline; changed.versionHash = "v2"
        XCTAssertNil(request.command(current: card, history: [source], pipeline: changed))
        XCTAssertNil(request.command(current: nil, history: [source], pipeline: pipeline))
        XCTAssertNil(request.command(current: card, history: [source], pipeline: nil))
    }
    func testMissingForeignAndUnsupportedStateHaveNoRestoreCommand() {
        let pipeline = Fix.pipeline(), source = fixtureRun()
        for card in [
            Fix.card("task", state: .running), Fix.card("task", state: .done),
            Fix.card("task", state: .cancelled), Fix.card("task", stage: "gate"),
            Fix.card("task", project: Fix.other)
        ] {
            let request = WIPRestoreRequest(card: card, run: source, pipeline: pipeline)
            XCTAssertFalse(request.isAvailable)
            XCTAssertNil(request.command(current: card, history: [source], pipeline: pipeline))
        }
        let card = Fix.card("task")
        for bad in [fixtureRun(ref: nil), fixtureRun(ref: ""), fixtureRun("foreign")] {
            XCTAssertFalse(WIPRestoreRequest(card: card, run: bad, pipeline: pipeline).isAvailable)
        }
    }
    func testSupportedAgentStatesDoNotRequireInventedProcessFacts() {
        for state: TaskState in [.queued(nil), .retryWait(.gateFailed), .paused, .waitingHuman(.question)] {
            let card = Fix.card("task", state: state), source = fixtureRun(), pipeline = Fix.pipeline()
            XCTAssertNotNil(WIPRestoreRequest(card: card, run: source, pipeline: pipeline)
                .command(current: card, history: [source], pipeline: pipeline))
        }
    }
}
