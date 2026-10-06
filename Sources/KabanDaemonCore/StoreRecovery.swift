import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    /// Called while the host owns its writer lease, before creating the scheduler or XPC listener.
    /// Any failure leaves startup closed. This pass never starts an agent.
    @discardableResult
    public func recoverProduction(passId: UUID, at: Date, workspaceRoot: String) throws -> [DurableReceipt] {
        projectOperations.lock(); defer { projectOperations.unlock() }
        if let cached = try database.read({ db -> Data? in
            guard try String.fetchOne(db, sql: "SELECT state FROM production_recovery WHERE id = ?", arguments: [passId.uuidString]) == "finished" else { return nil }
            return try Data.fetchOne(db, sql: "SELECT payload FROM recovery WHERE id = ?", arguments: [passId.uuidString])
        }) { return try Self.decode([DurableReceipt].self, cached) }
        try database.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO production_recovery(id, state) VALUES (?, 'running')", arguments: [passId.uuidString])
        }
        try stopStageProcesses()
        try stopRecordedProcesses()
        try database.write { db in try db.execute(sql: "UPDATE mcp_run_token SET revoked = 1, restart_revoked = 1") }
        _ = try restoreInstalledMCPConfigs()
        // Recover a fast-forward whose git action happened before its fact was recorded.
        let forwards = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload, lease_id FROM effect WHERE status = 'claimed' AND external_fact IS NULL")
        }
        for row in forwards {
            let item = try Self.decode(PendingEffect.self, row["payload"])
            guard case .fastForwardMerge = item.effect,
                  let leaseId: String = row["lease_id"], let intent = try mergeIntent(item.taskId),
                  let clone = try readyClone(item.taskId) else { continue }
            let task = try database.read { db in try Self.task(item.taskId, db: db) }
            if try TaskClone.mainCommit(clone.projectPath, identity: projectIdentity(task)) == intent.tip {
                let fact = ExternalEffectFact(actionId: item.id + "/merge", phase: .finished, outcome: .merged)
                _ = try commitEffectResult(effectId: item.id, leaseId: leaseId, fact: fact, at: at)
            }
        }
        _ = try recoverEffectExecution(at: at, reclaimUnexpired: true)
        let preparing = try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM task_clone").map { try Self.decode(TaskCloneRecord.self, $0) }
        }
        for clone in preparing where clone.phase == "preparing" {
            let task = try database.read { db in try Self.task(clone.taskId, db: db) }
            if task.machine.state.status != .cancelled && task.machine.state.status != .done {
                _ = try prepareTaskClone(taskId: clone.taskId, at: at, workspaceRoot: clone.workspaceRoot)
            }
        }
        let receipts = try recover(passId: passId, at: at)
        _ = try recoverEffectExecution(at: at, reclaimUnexpired: true)
        // Stops precede rollback. Stage commits use their durable markers; merge uses git facts.
        _ = try runProcessPass(owner: "recovery", at: at, workspaceRoot: workspaceRoot, runner: nil)
        for index in 0..<64 {
            let before = try pendingEffectItems().map(\.id)
            _ = try runStagePass(owner: "recovery", at: at)
            _ = try runMergePass(owner: "recovery", at: at, workspaceRoot: workspaceRoot)
            _ = try runClonePass(owner: "recovery", at: at, workspaceRoot: workspaceRoot)
            if try pendingEffectItems().map(\.id) == before { break }
            guard index < 63 else { throw POSIXError(.EBUSY) }
        }
        try database.write { db in
            try db.execute(sql: "UPDATE production_recovery SET state = 'finished' WHERE id = ?", arguments: [passId.uuidString])
        }
        return receipts
    }

    static func migrateStageProcesses(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE stage_process (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE production_recovery (id TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL)")
        try db.execute(sql: "ALTER TABLE mcp_run_token ADD COLUMN restart_revoked INTEGER NOT NULL DEFAULT 0")
    }

    struct StageProcessRecord: Codable {
        var pid: Int32
        var processGroup: Int32
        var birth: ProcessGroup.ProcessBirth
    }

    func runStageCommand(command: String, cwd: String, environment: [String: String], timeout: TimeInterval) throws -> StageCommand.Result {
        let id = UUID().uuidString
        let result = try StageCommand.run(command: command, cwd: cwd, environment: environment, timeout: timeout) { handle in
            let record = StageProcessRecord(pid: handle.pid, processGroup: handle.processGroup, birth: handle.birth)
            try self.database.write { db in
                try db.execute(sql: "INSERT INTO stage_process(id, payload) VALUES (?, ?)", arguments: [id, try Self.encode(record)])
            }
        }
        try database.write { db in try db.execute(sql: "DELETE FROM stage_process WHERE id = ?", arguments: [id]) }
        return result
    }

    private func stopStageProcesses() throws {
        let rows = try database.read { db in try Row.fetchAll(db, sql: "SELECT id, payload FROM stage_process") }
        for row in rows {
            let record = try Self.decode(StageProcessRecord.self, row["payload"])
            do {
                _ = try ProcessGroup.stop(pid: record.pid, processGroup: record.processGroup, birth: record.birth)
                let deadline = Date().addingTimeInterval(5)
                while ProcessGroup.isExecuting(record.pid, birth: record.birth) {
                    _ = ProcessGroup.poll(record.pid)
                    guard Date() < deadline else { throw POSIXError(.EBUSY) }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            } catch ProcessGroup.Failure.foreignGroup {
                // The original gate is gone; never signal a reused PID.
            }
            let id: String = row["id"]
            try database.write { db in try db.execute(sql: "DELETE FROM stage_process WHERE id = ?", arguments: [id]) }
        }
    }

    private func stopRecordedProcesses() throws {
        for var record in try allProcessRecords() where record.state == "running" {
            let birth = ProcessGroup.ProcessBirth(seconds: record.birthSeconds, microseconds: record.birthMicroseconds)
            do {
                _ = try ProcessGroup.stop(pid: record.pid, processGroup: record.processGroup, birth: birth)
                let deadline = Date().addingTimeInterval(5)
                while ProcessGroup.isExecuting(record.pid, birth: birth) {
                    _ = ProcessGroup.poll(record.pid)
                    guard Date() < deadline else { throw POSIXError(.EBUSY) }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                record.exitClass = "daemon_restart"
                record.state = "stopped"
            } catch ProcessGroup.Failure.foreignGroup {
                // A reused PID is never a reason to signal the new process or its group.
                record.state = "detached"
                record.exitClass = "foreign_pid"
            }
            record.passLines.append("process recovery \(record.runId) \(record.exitClass ?? "stopped")")
            try saveProcess(record)
        }
    }
}
