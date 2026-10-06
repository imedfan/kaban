import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

extension ProcessControlTests {
    func testFinishedRecoveryReceiptDoesNotStopALaterRun() throws {
        let f = try fixture()
        _ = try launch(f, "later")
        let pass = UUID()
        let receipt = try f.store.recoverProduction(passId: pass, at: at, workspaceRoot: f.workspace)
        _ = try apply(f, "later", .start("new-run"), at: at)
        let token = try f.store.issueRunToken(taskId: "later", at: at)
        _ = try f.store.runProcessPass(owner: "test", at: at, workspaceRoot: f.workspace, runner: "/bin/sleep", runnerArguments: ["30"])
        let record = try XCTUnwrap(f.store.allProcessRecords().first)
        XCTAssertEqual(try f.store.recoverProduction(passId: pass, at: at, workspaceRoot: f.workspace), receipt)
        XCTAssertEqual(try task(f, "later").machine.state, .running)
        XCTAssertTrue(ProcessGroup.isExecuting(record.pid, birth: .init(seconds: record.birthSeconds, microseconds: record.birthMicroseconds)))
        XCTAssertNoThrow(try f.store.requireBoardToken(token))
    }

    func testRecoveryStopsAnOrphanedGateGroup() throws {
        let f = try fixture()
        let handle = try ProcessGroup.spawn(executable: "/bin/sleep", arguments: ["30"], workingDirectory: f.root.path, environment: [:], standardOutput: f.root.appendingPathComponent("gate.out").path, standardError: f.root.appendingPathComponent("gate.err").path)
        defer { _ = try? ProcessGroup.stop(pid: handle.pid, processGroup: handle.processGroup, birth: handle.birth) }
        let record = KabanStore.StageProcessRecord(pid: handle.pid, processGroup: handle.processGroup, birth: handle.birth)
        try f.store.database.write { db in
            try db.execute(sql: "INSERT INTO stage_process(id, payload) VALUES ('gate', ?)", arguments: [try KabanStore.encode(record)])
        }
        let reopened = try KabanStore(path: f.path)
        _ = try reopened.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertFalse(ProcessGroup.isExecuting(handle.pid, birth: handle.birth))
        XCTAssertEqual(try reopened.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stage_process") }, 0)
    }

    func testRecoveryCrashBeforeProcessRecordNeverExecutesRunner() throws {
        let f = try fixture()
        _ = try launch(f, "unrecorded")
        let clone = try f.store.prepareTaskClone(taskId: "unrecorded", at: at, workspaceRoot: f.workspace)
        try f.store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_spawn_record BEFORE INSERT ON agent_process BEGIN SELECT RAISE(ABORT, 'crash'); END")
        }
        XCTAssertThrowsError(try f.store.runProcessPass(owner: "test", at: at, workspaceRoot: f.workspace, runner: "/bin/sh", runnerArguments: ["-c", "touch spawned.txt"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.clonePath + "/spawned.txt"))
        try f.store.database.write { db in try db.execute(sql: "DROP TRIGGER fail_spawn_record") }
        _ = try f.store.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try task(f, "unrecorded").machine.state, .retryWait(.daemonRestart))
        XCTAssertTrue(try f.store.agentProcesses().isEmpty)
    }

    func testRecoveryStopsOwnedProcessAndPreservesWIPWithoutChargingAttempt() throws {
        var f = try fixture()
        let run = try launch(f, "recover")
        let clone = try f.store.prepareTaskClone(taskId: "recover", at: at, workspaceRoot: f.workspace)
        let token = try f.store.issueRunToken(taskId: "recover", at: at)
        _ = try f.store.runProcessPass(owner: "test", at: at, workspaceRoot: f.workspace, runner: "/bin/sleep", runnerArguments: ["30"])
        let record = try XCTUnwrap(f.store.agentProcesses().first)
        try "unfinished".write(toFile: clone.clonePath + "/draft.txt", atomically: true, encoding: .utf8)
        f.store = try KabanStore(path: f.path)
        let pass = UUID()
        let receipts = try f.store.recoverProduction(passId: pass, at: at, workspaceRoot: f.workspace)
        XCTAssertFalse(receipts.isEmpty)
        XCTAssertEqual(try task(f, "recover").machine.state, .retryWait(.daemonRestart))
        XCTAssertEqual(try task(f, "recover").machine.attemptsUsed, 0)
        XCTAssertEqual(try task(f, "recover").machine.runsSinceHuman, 0)
        XCTAssertEqual(try f.store.agentProcesses().first?.state, "stopped")
        let detail = try f.store.getTaskDetail("recover")
        let saved = try XCTUnwrap(detail.runs.first { $0.id == run })
        XCTAssertEqual(saved.status, .killed)
        XCTAssertEqual(saved.endReason, .daemonRestart)
        XCTAssertFalse(saved.countsTowardLimits)
        let ref = try XCTUnwrap(saved.wipRef)
        XCTAssertTrue(ref.hasPrefix("refs/kaban/wip/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.clonePath + "/draft.txt"))
        XCTAssertThrowsError(try f.store.requireBoardToken(token))
        let seq = try f.store.snapshot().seq
        XCTAssertEqual(try f.store.recoverProduction(passId: pass, at: at, workspaceRoot: f.workspace), receipts)
        XCTAssertEqual(try f.store.snapshot().seq, seq)
        XCTAssertEqual(try f.store.agentProcesses().first?.startId, record.startId)
        _ = try f.store.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try f.store.snapshot().seq, seq)
    }

    func testRecoveryDoesNotSignalAReusedPID() throws {
        let f = try fixture()
        _ = try launch(f, "reused")
        _ = try f.store.runProcessPass(owner: "test", at: at, workspaceRoot: f.workspace, runner: "/bin/sleep", runnerArguments: ["30"])
        var record = try XCTUnwrap(f.store.allProcessRecords().first)
        let realBirth = ProcessGroup.ProcessBirth(seconds: record.birthSeconds, microseconds: record.birthMicroseconds)
        defer { _ = try? ProcessGroup.stop(pid: record.pid, processGroup: record.processGroup, birth: realBirth) }
        record.birthSeconds -= 1
        try f.store.saveProcess(record)
        _ = try f.store.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertTrue(ProcessGroup.isExecuting(record.pid, birth: realBirth))
        XCTAssertEqual(try f.store.agentProcesses().first?.state, "detached")
        XCTAssertEqual(try f.store.agentProcesses().first?.exitClass, "foreign_pid")
        XCTAssertEqual(try task(f, "reused").machine.state, .retryWait(.daemonRestart))
    }

    func testRecoveryFindsWIPWrittenBeforeItsDatabaseReceipt() throws {
        let f = try fixture()
        let run = try launch(f, "wip-crash")
        let clone = try f.store.prepareTaskClone(taskId: "wip-crash", at: at, workspaceRoot: f.workspace)
        try "saved".write(toFile: clone.clonePath + "/draft.txt", atomically: true, encoding: .utf8)
        let identity = try XCTUnwrap(f.store.getSnapshot().projects.first?.identity)
        let ref = try TaskClone.saveWipAndReset(clone: clone.clonePath, runId: run, recorded: clone.clonePath, workspaceRoot: f.workspace, origin: f.origin, identity: identity)
        XCTAssertNil(try f.store.getTaskDetail("wip-crash").runs.first?.wipRef)
        _ = try f.store.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try f.store.getTaskDetail("wip-crash").runs.first?.wipRef, ref)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.clonePath + "/draft.txt"))
    }

    func testRecoveryKeepsFinalCompletionAndPausedStateAndRevokesTokens() throws {
        let f = try fixture()
        let run = try launch(f, "complete")
        _ = try f.store.prepareTaskClone(taskId: "complete", at: at, workspaceRoot: f.workspace)
        let token = try f.store.issueRunToken(taskId: "complete", at: at)
        _ = try apply(f, "complete", .completeStage(run, summary: "finished"), at: at)
        _ = try launch(f, "paused")
        _ = try apply(f, "paused", .pause, at: at)
        let reopened = try KabanStore(path: f.path)
        _ = try reopened.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try reopened.snapshot().tasks.first { $0.card.id == "paused" }?.machine.state, .paused)
        let detail = try reopened.getTaskDetail("complete")
        XCTAssertEqual(detail.runs.filter { $0.id == run }.count, 1)
        XCTAssertEqual(detail.runs.first?.status, .succeeded)
        XCTAssertEqual(detail.artifacts.filter { $0.kind == "summary" }.count, 1)
        XCTAssertThrowsError(try reopened.requireBoardToken(token))
        let before = try reopened.snapshot().seq
        _ = try reopened.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try reopened.snapshot().seq, before)
    }
}
