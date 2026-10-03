import XCTest
@testable import KabanBoardCore
import KabanProtocol

final class BoardSetStoreTests: XCTestCase {
    func testFirstLaunchShowsEveryProjectAndSurvivesRestart() {
        let storage = MemoryKeyValueStore()
        let store = BoardSetStore(storage: storage)
        store.bootstrap(projects: ["b", "a"])
        XCTAssertFalse(store.restoredFromSavedSet)
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["b", "a"])

        let again = BoardSetStore(storage: storage)
        again.bootstrap(projects: ["b", "a"])
        XCTAssertTrue(again.restoredFromSavedSet)
        XCTAssertEqual(again.visibleProjectIds.map(\.rawValue), ["b", "a"])
    }

    func testHideOnlyHidesAndNewProjectIsAppended() {
        let storage = MemoryKeyValueStore()
        let store = BoardSetStore(storage: storage)
        store.bootstrap(projects: ["a", "b", "c"])
        store.hide("b")
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["a", "c"])
        store.apply(.projectAdded(Fix.project("d", name: "новый")))
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["a", "c", "d"])
        store.apply(.projectAdded(Fix.project("d", name: "новый")))
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["a", "c", "d"])

        let restarted = BoardSetStore(storage: storage)
        restarted.bootstrap(projects: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(restarted.visibleProjectIds.map(\.rawValue), ["a", "c", "d", "e"])
        XCTAssertFalse(restarted.visibleProjectIds.contains("b"))
    }

    func testReorderAndFocusShortcut() {
        let store = BoardSetStore(storage: MemoryKeyValueStore())
        store.bootstrap(projects: ["a", "b", "c"])
        store.moveRight("a")
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["b", "a", "c"])
        store.moveLeft("c")
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["b", "c", "a"])
        store.moveLeft("b")
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["b", "c", "a"])
        store.moveRight("a")
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["b", "c", "a"])
        store.show("b", at: 2)
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["c", "a", "b"])
        XCTAssertEqual(store.focusIndex(forShortcut: 1), 0)
        XCTAssertEqual(store.focusIndex(forShortcut: 3), 2)
        XCTAssertNil(store.focusIndex(forShortcut: 4))
        XCTAssertNil(store.focusIndex(forShortcut: 9))
        XCTAssertNil(store.focusIndex(forShortcut: 0))
    }

    func testRemovingProjectDropsItAndEmptySavedSetStaysEmpty() {
        let storage = MemoryKeyValueStore()
        let store = BoardSetStore(storage: storage)
        store.bootstrap(projects: ["a"])
        store.hide("a")
        XCTAssertEqual(store.visibleProjectIds, [])
        let restarted = BoardSetStore(storage: storage)
        restarted.bootstrap(projects: ["a"])
        XCTAssertEqual(restarted.visibleProjectIds, [])
        restarted.apply(.projectRemoved("a"))
        restarted.bootstrap(projects: ["a"])
        XCTAssertEqual(restarted.visibleProjectIds.map(\.rawValue), ["a"], "удалённый из known проект снова новый")
    }

    func testBadgesIgnoreVisibility() {
        let waiting = Fix.card("t-1", state: .waitingHuman(.question))
        let projection = BoardProjection(snapshot: Fix.snapshot(tasks: [waiting]))
        let store = BoardSetStore(storage: MemoryKeyValueStore())
        store.bootstrap(projects: [Fix.project])
        store.hide(Fix.project)
        XCTAssertTrue(store.visibleProjectIds.isEmpty)
        XCTAssertEqual(projection.lanes(orderedBy: store.visibleProjectIds), [])
        XCTAssertEqual(projection.badgeCounts(for: Fix.project).waitingHuman, 1)
        XCTAssertEqual(projection.tasks["t-1"]?.state, .waitingHuman(.question))
    }
}

final class DropRulesTests: XCTestCase {
    let pipeline = Fix.pipeline()

    func testBackwardAllowsAndRunningAsksToInterrupt() {
        let running = Fix.card("t-1", stage: "dev", state: .running)
        let backlog = Fix.stage("backlog", .queue, order: 0)
        let decision = DropRules.evaluate(card: running, target: backlog, in: pipeline)
        XCTAssertEqual(decision, .allowed(interruptConfirmation: DropRules.interruptConfirmation))

        let queued = Fix.card("t-1", stage: "test", state: .queued(nil))
        XCTAssertEqual(
            DropRules.evaluate(card: queued, target: Fix.stage("dev", .agent, order: 1), in: pipeline),
            .allowed(interruptConfirmation: nil)
        )
        let waiting = Fix.card("t-1", stage: "dev", state: .retryWait(.crash))
        XCTAssertEqual(
            DropRules.evaluate(card: waiting, target: backlog, in: pipeline),
            .allowed(interruptConfirmation: nil)
        )
    }

    func testForwardIsForbiddenExceptBacklogToNextStage() {
        let backlogCard = Fix.card("t-1", stage: "backlog", state: .queued(nil))
        XCTAssertEqual(
            DropRules.evaluate(card: backlogCard, target: Fix.stage("dev", .agent, order: 1), in: pipeline),
            .allowed(interruptConfirmation: nil)
        )
        XCTAssertEqual(
            DropRules.evaluate(card: backlogCard, target: Fix.stage("test", .agent, order: 3), in: pipeline),
            .forbidden(.forwardMove)
        )
        let dev = Fix.card("t-1", stage: "dev", state: .queued(nil))
        XCTAssertEqual(
            DropRules.evaluate(card: dev, target: Fix.stage("test", .agent, order: 3), in: pipeline),
            .forbidden(.forwardMove)
        )
        XCTAssertEqual(
            DropRules.evaluate(card: dev, target: Fix.stage("done", .terminal, order: 4), in: pipeline),
            .forbidden(.forwardMove)
        )
    }

    func testGateColumnCrossProjectAndSameColumn() {
        let dev = Fix.card("t-1", stage: "dev", state: .queued(nil))
        XCTAssertEqual(
            DropRules.evaluate(card: dev, target: Fix.stage("gate", .gate, order: 2), in: pipeline),
            .forbidden(.gateColumn)
        )
        let gateNext = Fix.pipeline([
            Fix.stage("backlog", .queue, order: 0),
            Fix.stage("gate", .gate, order: 1),
            Fix.stage("dev", .agent, order: 2),
        ])
        let backlog = Fix.card("t-1", stage: "backlog")
        XCTAssertEqual(
            DropRules.evaluate(card: backlog, target: Fix.stage("gate", .gate, order: 1), in: gateNext),
            .forbidden(.gateColumn)
        )
        XCTAssertEqual(
            DropRules.evaluate(card: dev, target: Fix.stage("dev", .agent, order: 1), in: pipeline),
            .forbidden(.sameColumn)
        )
        XCTAssertEqual(
            DropRules.evaluate(card: dev, target: Fix.stage("dev", .agent, order: 1), in: Fix.pipeline(project: Fix.other)),
            .forbidden(.crossProject)
        )
        XCTAssertEqual(
            DropRules.evaluate(card: dev, target: Fix.stage("nope", .agent, order: 9), in: pipeline),
            .forbidden(.unknownStage)
        )
        XCTAssertEqual(DropForbidReason.gateColumn.text, "В столбец гейта нельзя перетащить задачу")
    }
}
