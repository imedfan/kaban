import XCTest
@testable import KabanBoardCore
import KabanProtocol

final class BoardSetTests: XCTestCase {
    func testAddAppendsOnceAndReaddDoesNotTouchAddedOrder() {
        var set = BoardSet()
        set.add("a")
        set.add("b", at: 0)
        XCTAssertEqual(set.lanes.map(\.rawValue), ["b", "a"])
        XCTAssertEqual(set.addedOrder.map(\.rawValue), ["a", "b"])
        set.add("a", at: 0)
        XCTAssertEqual(set.lanes.map(\.rawValue), ["a", "b"])
        XCTAssertEqual(set.addedOrder.map(\.rawValue), ["a", "b"])
    }

    func testMoveChangesOnlyDisplayOrder() {
        var set = BoardSet(lanes: ["a", "b", "c"])
        set.move("a", to: 2)
        XCTAssertEqual(set.lanes.map(\.rawValue), ["b", "c", "a"])
        XCTAssertEqual(set.addedOrder.map(\.rawValue), ["a", "b", "c"])
        set.shiftDisplay("c", by: -1)
        XCTAssertEqual(set.lanes.map(\.rawValue), ["c", "b", "a"])
        XCTAssertEqual(set.addedOrder.map(\.rawValue), ["a", "b", "c"])
    }

    func testRemoveAndPruneDropBothOrdersAndReaddGoesToTheEnd() {
        var set = BoardSet(lanes: ["a", "b", "c"])
        set.remove("b")
        XCTAssertEqual(set.lanes.map(\.rawValue), ["a", "c"])
        XCTAssertEqual(set.addedOrder.map(\.rawValue), ["a", "c"])
        set.add("b", at: 0)
        XCTAssertEqual(set.lanes.map(\.rawValue), ["b", "a", "c"])
        XCTAssertEqual(set.addedOrder.map(\.rawValue), ["a", "c", "b"])
        set.prune(existing: ["a", "b"])
        XCTAssertEqual(set.lanes.map(\.rawValue), ["b", "a"])
        XCTAssertEqual(set.addedOrder.map(\.rawValue), ["a", "b"])
    }

    func testMissingAddedOrderDecodesAsDisplayOrder() throws {
        let array = Data("[\"b\",\"a\"]".utf8)
        let fromArray = try JSONDecoder().decode(BoardSet.self, from: array)
        XCTAssertEqual(fromArray.lanes.map(\.rawValue), ["b", "a"])
        XCTAssertEqual(fromArray.addedOrder.map(\.rawValue), ["b", "a"])

        let object = Data("{\"lanes\":[\"b\",\"a\"]}".utf8)
        let fromObject = try JSONDecoder().decode(BoardSet.self, from: object)
        XCTAssertEqual(fromObject.lanes.map(\.rawValue), ["b", "a"])
        XCTAssertEqual(fromObject.addedOrder.map(\.rawValue), ["b", "a"])

        var moved = BoardSet(lanes: ["a", "b"])
        moved.move("a", to: 1)
        let again = try JSONDecoder().decode(BoardSet.self, from: JSONEncoder().encode(moved))
        XCTAssertEqual(again, moved)
        XCTAssertEqual(again.addedOrder.map(\.rawValue), ["a", "b"])
        XCTAssertEqual(again.lanes.map(\.rawValue), ["b", "a"])
    }
}

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

    func testReorderKeepsAddedOrderAcrossRestart() {
        let storage = MemoryKeyValueStore()
        let store = BoardSetStore(storage: storage)
        store.bootstrap(projects: ["a", "b", "c"])
        XCTAssertEqual(store.addedOrder.map(\.rawValue), ["a", "b", "c"])
        store.move("a", to: 2)
        store.moveLeft("c")
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["c", "b", "a"])
        XCTAssertEqual(store.addedOrder.map(\.rawValue), ["a", "b", "c"])
        store.hide("b")
        XCTAssertEqual(store.addedOrder.map(\.rawValue), ["a", "c"])
        store.show("b", at: 0)
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["b", "c", "a"])
        XCTAssertEqual(store.addedOrder.map(\.rawValue), ["a", "c", "b"])

        let restarted = BoardSetStore(storage: storage)
        restarted.bootstrap(projects: ["a", "b", "c"])
        XCTAssertEqual(restarted.visibleProjectIds.map(\.rawValue), ["b", "c", "a"])
        XCTAssertEqual(restarted.addedOrder.map(\.rawValue), ["a", "c", "b"])
    }

    func testLegacyLaneArrayBecomesAddedOrder() throws {
        let storage = MemoryKeyValueStore()
        storage.set(Data("[\"b\",\"a\"]".utf8), forKey: BoardSetStorageKey.lanes)
        let known: [ProjectID] = ["a", "b"]
        storage.set(try JSONEncoder().encode(known), forKey: BoardSetStorageKey.known)
        let store = BoardSetStore(storage: storage)
        store.bootstrap(projects: ["a", "b"])
        XCTAssertTrue(store.restoredFromSavedSet)
        XCTAssertEqual(store.visibleProjectIds.map(\.rawValue), ["b", "a"])
        XCTAssertEqual(store.addedOrder.map(\.rawValue), ["b", "a"])
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
        let backlogCard = Fix.card("t-1", stage: "backlog", state: .queued(nil), hasAcceptanceCriteria: true)
        XCTAssertEqual(
            DropRules.evaluate(card: backlogCard, target: Fix.stage("dev", .agent, order: 1), in: pipeline),
            .allowed(interruptConfirmation: nil)
        )
        let withoutCriteria = Fix.card("t-1", stage: "backlog", state: .queued(nil))
        XCTAssertEqual(
            DropRules.evaluate(card: withoutCriteria, target: Fix.stage("dev", .agent, order: 1), in: pipeline),
            .forbidden(.forwardMove)
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

    func testAcceptanceCriteriaAndAgentGates() {
        let withGates = Fix.pipeline([
            Fix.stage("backlog", .queue, order: 0),
            Fix.stage("review", .agent, order: 1, gates: ["swift test"]),
            Fix.stage("dev", .agent, order: 2),
        ])
        let ready = Fix.card("t-1", stage: "backlog", state: .queued(nil), hasAcceptanceCriteria: true)
        XCTAssertEqual(
            DropRules.evaluate(card: ready, target: Fix.stage("review", .agent, order: 1, gates: ["swift test"]), in: withGates),
            .allowed(interruptConfirmation: nil),
            "гейты цели не мешают войти в соседнюю стадию"
        )
        XCTAssertEqual(
            DropRules.evaluate(card: ready, target: Fix.stage("dev", .agent, order: 2), in: withGates),
            .forbidden(.forwardMove)
        )
        XCTAssertTrue(DropRules.crossesStagesWithGates(from: 0, to: 2, stages: withGates.stages))
        let bare = [
            Fix.stage("backlog", .queue, order: 0),
            Fix.stage("review", .agent, order: 1),
            Fix.stage("dev", .agent, order: 2),
        ]
        XCTAssertFalse(DropRules.crossesStagesWithGates(from: 0, to: 2, stages: bare))
        XCTAssertTrue(DropRules.crossesStagesWithGates(
            from: 0, to: 2,
            stages: [
                Fix.stage("backlog", .queue, order: 0),
                Fix.stage("gate", .gate, order: 1),
                Fix.stage("dev", .agent, order: 2),
            ]
        ))
    }
}
