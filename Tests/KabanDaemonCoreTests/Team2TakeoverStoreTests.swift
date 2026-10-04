import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class Team2TakeoverStoreTests: XCTestCase {
    private func fixture() throws -> (URL, PipelineConfig, TaskCard) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pipeline = try XCTUnwrap(PipelineValidator.validate(yaml: PipelineTemplate.defaultYAML.replacingOccurrences(of: "model:", with: "model: test")).config)
        let card = TaskCard(id: "t", projectId: "p", title: "test", stageId: "ignored", state: .queued(nil), updatedAt: Date(timeIntervalSince1970: 1))
        return (root, pipeline, card)
    }
    func testCreationTransitionSnapshotReopenAndExactEffects() throws {
        let (root, pipeline, card) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        let created = try store.createTask(card: card, pipeline: pipeline, commandId: UUID(), at: card.updatedAt)
        XCTAssertEqual(created.firstSeq, 1)
        XCTAssertEqual(created.task.machine.stageId, pipeline.entryStage?.id)
        _ = try store.apply(.start("intake"), taskId: card.id, commandId: UUID(), at: card.updatedAt)
        let startId = UUID()
        let running = try store.apply(.start("run"), taskId: card.id, commandId: startId, at: card.updatedAt)
        XCTAssertEqual(running.task.machine.state, .running)
        let effects = try store.pendingEffects()
        XCTAssertTrue(effects.contains { $0.commandId == startId && $0.effects.contains { if case .startAgentRun = $0 { true } else { false } } })
        let reopened = try KabanStore(path: path)
        XCTAssertEqual(try reopened.snapshot().tasks, [running.task])
        XCTAssertEqual(try reopened.snapshot().seq, running.lastSeq)
        XCTAssertEqual(try reopened.pendingEffects(), effects)
        let journal = try reopened.events()
        XCTAssertEqual(journal.map(\.seq), Array(1...running.lastSeq))
        XCTAssertEqual(journal.last?.commandId, startId)
        try reopened.acknowledgeEffects(commandId: startId)
        XCTAssertFalse(try store.pendingEffects().contains { $0.commandId == startId })
    }
    func testDedupReplayAfterReopenAndPayloadConflict() throws {
        let (root, pipeline, card) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let id = UUID(); let store = try KabanStore(path: path)
        let original = try store.createTask(card: card, pipeline: pipeline, commandId: id, at: card.updatedAt)
        let reopened = try KabanStore(path: path)
        XCTAssertEqual(try reopened.createTask(card: card, pipeline: pipeline, commandId: id, at: Date()), original)
        XCTAssertEqual(try reopened.events().count, 1)
        var changed = card; changed.title = "different"
        XCTAssertThrowsError(try reopened.createTask(card: changed, pipeline: pipeline, commandId: id, at: Date())) { XCTAssertEqual($0 as? StoreError, .commandIdConflict) }
        XCTAssertEqual(try reopened.snapshot().tasks, [original.task])
    }
    func testFailureRollsBackProjectionJournalReceiptAndOutbox() throws {
        let (root, pipeline, card) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        let id = UUID(); var invalid = pipeline; invalid.stages = []
        XCTAssertThrowsError(try store.createTask(card: card, pipeline: invalid, commandId: id, at: Date()))
        XCTAssertEqual(try store.snapshot().seq, 0)
        XCTAssertTrue(try store.snapshot().tasks.isEmpty)
        XCTAssertTrue(try store.pendingEffects().isEmpty)
        // The failed command ID was not consumed and succeeds with a valid request.
        _ = try store.createTask(card: card, pipeline: pipeline, commandId: id, at: Date())
        let before = try store.snapshot()
        XCTAssertThrowsError(try store.apply(.cancel(keepBranch: false), taskId: "missing", commandId: UUID(), at: Date()))
        XCTAssertEqual(try store.snapshot().seq, before.seq)
        XCTAssertEqual(try store.snapshot().tasks, before.tasks)
    }
    func testDatabaseFailureAfterProjectionWriteRollsBackEntireCommand() throws {
        let (root, pipeline, card) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        _ = try store.createTask(card: card, pipeline: pipeline, commandId: UUID(), at: Date())
        let before = try store.snapshot()
        let inspection = try DatabaseQueue(path: path)
        try inspection.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_journal BEFORE INSERT ON event BEGIN SELECT RAISE(ABORT, 'injected disk write failure'); END")
        }
        let id = UUID()
        XCTAssertThrowsError(try store.apply(.start("intake"), taskId: card.id, commandId: id, at: Date()))
        XCTAssertEqual(try store.snapshot().seq, before.seq)
        XCTAssertEqual(try store.snapshot().tasks, before.tasks)
        XCTAssertTrue(try store.pendingEffects().isEmpty)
        try inspection.write { db in try db.execute(sql: "DROP TRIGGER fail_journal") }
        // No receipt survives the aborted transaction: retry actually performs the transition.
        let applied = try store.apply(.start("intake"), taskId: card.id, commandId: id, at: Date())
        XCTAssertNotEqual(applied.task.machine.stageId, before.tasks.first?.machine.stageId)
    }
    func testCancelSupersedesPendingRunLaunchAtomically() throws {
        let (root, pipeline, card) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        _ = try store.createTask(card: card, pipeline: pipeline, commandId: UUID(), at: Date())
        _ = try store.apply(.start("intake"), taskId: card.id, commandId: UUID(), at: Date())
        _ = try store.apply(.start("run"), taskId: card.id, commandId: UUID(), at: Date())
        let cancelled = try store.apply(.cancel(keepBranch: false), taskId: card.id, commandId: UUID(), at: Date())
        XCTAssertEqual(cancelled.task.machine.state, .cancelled)
        let effects = try store.pendingEffects().flatMap(\.effects)
        XCTAssertFalse(effects.contains { if case .startAgentRun = $0 { true } else { false } })
        XCTAssertTrue(effects.contains(.killRun("run")))
        XCTAssertTrue(effects.contains(.cleanupClone(keepBranch: false)))
    }
    func testRestartRecoveryRefundsRunningCountersAndCanReplayPass() throws {
        let (root, pipeline, card) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        _ = try store.createTask(card: card, pipeline: pipeline, commandId: UUID(), at: Date())
        _ = try store.apply(.start("intake"), taskId: card.id, commandId: UUID(), at: Date())
        _ = try store.apply(.start("run"), taskId: card.id, commandId: UUID(), at: Date())
        let core = KabanDaemonCore(store: try KabanStore(path: path))
        let pass = UUID()
        let recovered = try core.recover(passId: pass, at: Date())
        XCTAssertEqual(recovered.count, 1)
        let pending = try core.store.pendingEffects()
        XCTAssertFalse(pending.flatMap(\.effects).contains { if case .startAgentRun = $0 { true } else { false } })
        XCTAssertTrue(pending.flatMap(\.effects).contains(.saveWipAndRollback("run")))
        XCTAssertEqual(recovered.first?.task.machine.state, .retryWait(.daemonRestart))
        XCTAssertEqual(recovered.first?.task.machine.runsSinceHuman, 0)
        let seq = try core.store.snapshot().seq
        XCTAssertEqual(try core.recover(passId: pass, at: Date()), recovered)
        XCTAssertEqual(try core.store.snapshot().seq, seq)
        XCTAssertTrue(try core.recover(passId: UUID(), at: Date()).isEmpty)
    }
}
