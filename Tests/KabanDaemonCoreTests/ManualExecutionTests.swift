import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

extension ProcessControlTests {
    func savedWIP(_ f: Fixture, id: TaskID) throws -> (RunID, TaskCloneSnapshot, String) {
        let run = try launch(f, id)
        let clone = try f.store.prepareTaskClone(taskId: id, at: at, workspaceRoot: f.workspace)
        try "selected snapshot".write(toFile: clone.clonePath + "/draft.txt", atomically: true, encoding: .utf8)
        _ = try apply(f, id, .runFailed(run, .crash), at: at)
        _ = try pass(f, at: at, runner: nil)
        return (run, clone, try XCTUnwrap(f.store.getTaskDetail(id).runs.first?.wipRef))
    }

    func testSelectedWIPRestoresCloneAfterReceiptAndPreservesMainAndRunHistory() throws {
        let f = try fixture()
        let (run, clone, ref) = try savedWIP(f, id: "restore")
        XCTAssertEqual(try f.store.execute(.init(command: .pauseTask(taskId: "restore"))).result, .ok)
        let main = try TaskClone.mainCommit(f.origin, identity: nil)
        let head = try TaskClone.head(clone.clonePath, identity: nil)
        let history = try f.store.getTaskDetail("restore").runs
        try "backup me".write(toFile: clone.clonePath + "/local.txt", atomically: true, encoding: .utf8)
        let command = CommandEnvelope(command: .restoreWIP(taskId: "restore", runId: run, wipRef: ref))
        let before = try f.store.getSnapshot().seq
        let reply = try f.store.execute(command)
        XCTAssertEqual(reply.result, .ok)
        XCTAssertEqual(try f.store.getSnapshot().seq, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.clonePath + "/draft.txt"))
        _ = try f.store.runWIPRestorePass(owner: "test", at: at)
        XCTAssertEqual(try String(contentsOfFile: clone.clonePath + "/draft.txt", encoding: .utf8), "selected snapshot")
        XCTAssertEqual(try TaskClone.head(clone.clonePath, identity: nil), head)
        XCTAssertEqual(try TaskClone.mainCommit(f.origin, identity: nil), main)
        XCTAssertEqual(try f.store.getTaskDetail("restore").runs, history)
        XCTAssertEqual(try task(f, "restore").machine.state, .paused)
        let events = try f.store.events().filter { $0.commandId == command.commandId }
        XCTAssertTrue(events.contains { if case .wipRestored(let value) = $0.event { return value.runId == run && value.wipRef == ref }; return false })
        let backup = "refs/kaban/wip/restore-" + command.commandId.uuidString.lowercased()
        XCTAssertFalse(try TaskClone.wipCommit(clone: clone.clonePath, ref: backup, identity: nil).isEmpty)
        try "later edit".write(toFile: clone.clonePath + "/draft.txt", atomically: true, encoding: .utf8)
        let seq = try f.store.getSnapshot().seq
        XCTAssertEqual(try f.store.execute(command), reply)
        XCTAssertTrue(try f.store.runWIPRestorePass(owner: "test", at: at).isEmpty)
        XCTAssertEqual(try f.store.getSnapshot().seq, seq)
        XCTAssertEqual(try String(contentsOfFile: clone.clonePath + "/draft.txt", encoding: .utf8), "later edit")
    }

    func testRestoreLostReceiptUsesGitMarkerWithoutOverwritingLaterEdits() throws {
        var f = try fixture()
        let (run, clone, ref) = try savedWIP(f, id: "receipt")
        _ = try f.store.execute(.init(command: .pauseTask(taskId: "receipt")))
        let command = CommandEnvelope(command: .restoreWIP(taskId: "receipt", runId: run, wipRef: ref))
        _ = try f.store.execute(command)
        try f.store.database.write { try $0.execute(sql: "CREATE TRIGGER lost_restore BEFORE UPDATE OF status ON effect WHEN NEW.status = 'acknowledged' BEGIN SELECT RAISE(ABORT, 'crash before receipt'); END") }
        XCTAssertThrowsError(try f.store.runWIPRestorePass(owner: "test", at: at))
        XCTAssertEqual(try String(contentsOfFile: clone.clonePath + "/draft.txt", encoding: .utf8), "selected snapshot")
        XCTAssertFalse(try f.store.events().contains { $0.commandId == command.commandId })
        try "edit after action".write(toFile: clone.clonePath + "/draft.txt", atomically: true, encoding: .utf8)
        try f.store.database.write { try $0.execute(sql: "DROP TRIGGER lost_restore") }
        f.store = try KabanStore(path: f.path)
        _ = try f.store.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try String(contentsOfFile: clone.clonePath + "/draft.txt", encoding: .utf8), "edit after action")
        XCTAssertEqual(try f.store.getTaskDetail("receipt").feed.filter { $0.kind == "wip_restored" }.count, 1)
    }

    func testRestoreRejectsForeignRunAndChangedRefAndBlocksAdmissionWhilePending() throws {
        let f = try fixture()
        let (run, clone, ref) = try savedWIP(f, id: "stale")
        let invalid = try f.store.execute(.init(command: .restoreWIP(taskId: "stale", runId: "someone-else", wipRef: ref)))
        guard case .error = invalid.result else { return XCTFail("Foreign run accepted") }
        let command = CommandEnvelope(command: .restoreWIP(taskId: "stale", runId: run, wipRef: ref))
        XCTAssertEqual(try f.store.execute(command).result, .ok)
        XCTAssertTrue(try f.store.runSchedulerPass(at: at.addingTimeInterval(500)).isEmpty)
        try git(URL(fileURLWithPath: clone.clonePath), ["update-ref", ref, "HEAD"])
        _ = try f.store.runWIPRestorePass(owner: "test", at: at)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.clonePath + "/draft.txt"))
        XCTAssertFalse(try f.store.events().contains { if case .wipRestored = $0.event { true } else { false } })
        XCTAssertEqual(try f.store.getTaskDetail("stale").feed.filter { $0.kind == "wip_restore_failed" }.count, 1)
        XCTAssertEqual(try task(f, "stale").machine.state, .retryWait(.crash))
    }

    func testMoveSupersedesPendingRestoreWithCorrelatedCancellation() throws {
        let f = try fixture()
        let (run, clone, ref) = try savedWIP(f, id: "superseded")
        let command = CommandEnvelope(command: .restoreWIP(taskId: "superseded", runId: run, wipRef: ref))
        _ = try f.store.execute(command)
        XCTAssertEqual(try f.store.execute(.init(command: .moveTask(taskId: "superseded", stage: "backlog"))).result, .ok)
        XCTAssertTrue(try f.store.runWIPRestorePass(owner: "test", at: at).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.clonePath + "/draft.txt"))
        XCTAssertTrue(try f.store.events().contains { $0.commandId == command.commandId })
        XCTAssertEqual(try f.store.getTaskDetail("superseded").feed.filter { $0.kind == "wip_restore_cancelled" }.count, 1)
    }

    func testRuntimeManualPauseStopsProcessWhileGlobalAndProjectPauseDoNot() throws {
        let f = try fixture()
        let run = try launch(f, "manual")
        let scheduler = DaemonScheduler(store: f.store, workspaceRoot: f.workspace, runner: "/bin/sleep", runnerArguments: ["30"], onError: { XCTFail("Runtime failed: \($0)") })
        defer { scheduler.stop() }
        let deadline = Date().addingTimeInterval(4)
        while try f.store.agentProcesses().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let record = try XCTUnwrap(f.store.allProcessRecords().first)
        let birth = ProcessGroup.ProcessBirth(seconds: record.birthSeconds, microseconds: record.birthMicroseconds)
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        XCTAssertEqual(try f.store.execute(.init(command: .pauseAll)).result, .ok)
        XCTAssertEqual(try f.store.execute(.init(command: .pauseProject(projectId: project))).result, .ok)
        try f.store.runRuntimePass(at: Date(), workspaceRoot: f.workspace)
        XCTAssertTrue(ProcessGroup.isExecuting(record.pid, birth: birth))
        XCTAssertEqual(try task(f, "manual").machine.currentRunId, run)
        let command = CommandEnvelope(command: .pauseTask(taskId: "manual"))
        let reply = try f.store.execute(command)
        scheduler.wake()
        let stopped = Date().addingTimeInterval(4)
        while ProcessGroup.isExecuting(record.pid, birth: birth) && Date() < stopped { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(ProcessGroup.isExecuting(record.pid, birth: birth))
        XCTAssertEqual(try task(f, "manual").machine.state, .paused)
        XCTAssertEqual(try f.store.execute(command), reply)
        let cancel = CommandEnvelope(command: .cancelTask(taskId: "manual", keepBranch: true))
        _ = try f.store.execute(cancel)
        try f.store.runRuntimePass(at: Date(), workspaceRoot: f.workspace)
        XCTAssertNil(try f.store.getTaskDetail("manual").clonePath)
        XCTAssertEqual(try gitStatus(f.origin, ["show-ref", "--verify", "refs/kaban/archive/manual"]), 0)
    }

    func testRemovedRelinkedProjectArchivesAndCleansItsRecordedClone() throws {
        let f = try fixture()
        _ = try launch(f, "removed")
        let clone = try f.store.prepareTaskClone(taskId: "removed", at: at, workspaceRoot: f.workspace)
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let moved = f.root.appendingPathComponent("relinked")
        try FileManager.default.moveItem(atPath: f.origin, toPath: moved.path)
        XCTAssertEqual(try f.store.execute(.init(command: .relinkProject(projectId: project, path: moved.path))).result, .ok)
        XCTAssertEqual(try f.store.execute(.init(command: .removeProject(projectId: project))).result, .ok)
        _ = try f.store.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.clonePath))
        XCTAssertTrue(try f.store.getSnapshot().projects.isEmpty)
        XCTAssertEqual(try gitStatus(moved.path, ["show-ref", "--verify", "refs/kaban/archive/removed"]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path + "/.kaban/pipeline.yaml"))
    }

    func testModelOverrideResetsHumanCounterAndKeepsFrozenCurrentRun() throws {
        let f = try fixture()
        let run = try launch(f, "model-manual")
        let before = try f.store.getRunSpec(run)
        XCTAssertGreaterThan(try task(f, "model-manual").machine.runsSinceHuman, 0)
        let command = CommandEnvelope(command: .setModelOverride(taskId: "model-manual", stageId: "dev", model: "another-explicit"))
        XCTAssertEqual(try f.store.execute(command).result, .ok)
        XCTAssertEqual(try task(f, "model-manual").machine.runsSinceHuman, 0)
        XCTAssertEqual(try f.store.getRunSpec(run), before)
        XCTAssertEqual(try task(f, "model-manual").machine.currentRunId, run)
        XCTAssertTrue(try f.store.events().contains { $0.commandId == command.commandId })
    }
}
