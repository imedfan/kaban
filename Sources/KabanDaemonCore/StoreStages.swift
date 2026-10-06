import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    static func migrateStageExecution(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE stage_entry (
                task_id TEXT PRIMARY KEY NOT NULL,
                entry INTEGER NOT NULL,
                stage_id TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE stage_work (
                id TEXT PRIMARY KEY NOT NULL,
                task_id TEXT NOT NULL,
                entry INTEGER NOT NULL,
                stage_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                command TEXT NOT NULL,
                status TEXT NOT NULL,
                output TEXT NOT NULL DEFAULT '',
                code INTEGER NOT NULL DEFAULT 0,
                sha TEXT,
                effect_id TEXT
            )
            """)
        try db.execute(sql: """
            CREATE TABLE stage_pass_line (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL,
                line TEXT NOT NULL
            )
            """)
    }

    static func isDurableEffect(_ effect: TaskEffect) -> Bool {
        switch effect {
        case .recordTransition, .recordHumanRequest, .recordHumanAnswer, .raiseModelFlag,
             .raiseRateLimit, .raiseUsageExhausted, .raiseRunnerUnavailable, .requestModelProbe:
            return false
        default:
            return true
        }
    }

    /// Records one hook or commit intent for this stage entry. A replayed command never reaches this call.
    static func recordStageBoundary(before: TaskMachineState, after: DurableTask, pipeline: PipelineConfig, effects: [TaskEffect], commandId: CommandID, db: Database) throws {
        let taskId = after.card.id.rawValue
        let existing = try Int.fetchOne(db, sql: "SELECT entry FROM stage_entry WHERE task_id = ?", arguments: [taskId])
        let oldEntry = existing ?? 1
        let pending = effects.filter(isDurableEffect)
        for (index, effect) in pending.enumerated() {
            guard case .commitStage(let commit) = effect else { continue }
            let message = commitMessage(commit, stage: before.stageId, task: after.card.id)
            let effectId = "\(commandId.uuidString.lowercased())/\(index)"
            try insertWork(id: "\(taskId)/\(oldEntry)/commit", taskId: taskId, entry: oldEntry, stageId: before.stageId.rawValue, kind: "commit", command: message, effectId: effectId, db: db)
        }
        let changed = before.stageId != after.machine.stageId
        if changed {
            if let hook = pipeline.stage(before.stageId)?.hooks.onExit?.trimmingCharacters(in: .whitespacesAndNewlines), !hook.isEmpty {
                try insertWork(id: "\(taskId)/\(oldEntry)/exit", taskId: taskId, entry: oldEntry, stageId: before.stageId.rawValue, kind: "exit", command: hook, effectId: nil, db: db)
            }
            let newEntry = oldEntry + 1
            if let hook = pipeline.stage(after.machine.stageId)?.hooks.onEnter?.trimmingCharacters(in: .whitespacesAndNewlines), !hook.isEmpty {
                try insertWork(id: "\(taskId)/\(newEntry)/enter", taskId: taskId, entry: newEntry, stageId: after.machine.stageId.rawValue, kind: "enter", command: hook, effectId: nil, db: db)
            }
            try db.execute(sql: """
                INSERT INTO stage_entry(task_id, entry, stage_id) VALUES (?, ?, ?)
                ON CONFLICT(task_id) DO UPDATE SET entry = excluded.entry, stage_id = excluded.stage_id
                """, arguments: [taskId, newEntry, after.machine.stageId.rawValue])
        } else if existing == nil {
            try db.execute(sql: "INSERT INTO stage_entry(task_id, entry, stage_id) VALUES (?, ?, ?)", arguments: [taskId, oldEntry, before.stageId.rawValue])
        }
    }

    /// Runs pending hooks, gates, the result check, and at most one commit per stage entry.
    /// A second call reprints the same lines and does not spawn a hook or create a commit again.
    public func runStagePass(owner: String, at: Date) throws -> [String] {
        for _ in 0..<16 {
            if try runExitHook(at: at) { continue }
            if try runCommit(owner: owner, at: at) { continue }
            if try runEnterHook(at: at) { continue }
            if try runGateEffect(owner: owner, at: at) { continue }
            if try runResultEffect(owner: owner, at: at) { continue }
            if try runRollback(owner: owner, at: at) { continue }
            break
        }
        return try stageLines()
    }

    private func stageLines() throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT line FROM stage_pass_line ORDER BY id")
        }
    }

    private func remember(taskId: String, line: String) throws {
        let exists = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stage_pass_line WHERE task_id = ? AND line = ?", arguments: [taskId, line]) ?? 0
        }
        guard exists == 0 else { return }
        try database.write { db in
            try db.execute(sql: "INSERT INTO stage_pass_line(task_id, line) VALUES (?, ?)", arguments: [taskId, line])
        }
    }

    private struct WorkRow {
        var id: String
        var taskId: String
        var entry: Int
        var stageId: String
        var kind: String
        var command: String
        var status: String
        var output: String
        var code: Int
        var sha: String?
        var effectId: String?
    }

    private func workRows(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> [WorkRow] {
        try database.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                WorkRow(id: row["id"], taskId: row["task_id"], entry: Int(row["entry"] as Int64), stageId: row["stage_id"], kind: row["kind"], command: row["command"], status: row["status"], output: row["output"], code: Int(row["code"] as Int64), sha: row["sha"], effectId: row["effect_id"])
            }
        }
    }

    private func runExitHook(at: Date) throws -> Bool {
        let rows = try workRows("SELECT * FROM stage_work WHERE kind = 'exit' AND status != 'finished' ORDER BY entry, id")
        for row in rows {
            let task = try database.read { db in try Self.task(TaskID(rawValue: row.taskId), db: db) }
            guard task.machine.stageId.rawValue != row.stageId else { continue }
            return try performHook(row, at: at)
        }
        return false
    }

    private func runEnterHook(at: Date) throws -> Bool {
        let rows = try workRows("SELECT * FROM stage_work WHERE kind = 'enter' AND status != 'finished' ORDER BY entry, id")
        for row in rows {
            let task = try database.read { db in try Self.task(TaskID(rawValue: row.taskId), db: db) }
            guard task.machine.stageId.rawValue == row.stageId else { continue }
            guard try readyClone(TaskID(rawValue: row.taskId)) != nil else { return false }
            return try performHook(row, at: at)
        }
        return false
    }

    /// A `running` row was already handed to the process. Replay marks it finished and does not spawn.
    private func performHook(_ row: WorkRow, at: Date) throws -> Bool {
        if row.status == "running" {
            try finishWork(id: row.id, output: row.output, code: row.code, sha: nil)
            try remember(taskId: row.taskId, line: "stage \(row.taskId) hook \(row.stageId) \(row.kind) replay")
            return true
        }
        guard let clone = try readyClone(TaskID(rawValue: row.taskId)) else { return false }
        try database.write { db in
            try db.execute(sql: "UPDATE stage_work SET status = 'running' WHERE id = ? AND status = 'pending'", arguments: [row.id])
        }
        let stage = try database.read { db in try Self.task(TaskID(rawValue: row.taskId), db: db).pipeline.stage(StageID(rawValue: row.stageId)) }
        let result = try StageCommand.run(command: row.command, cwd: clone.clonePath, environment: StageCommand.environment(stage: stage?.agent?.env ?? [:]), timeout: TimeInterval(stage?.timeouts.wallSeconds ?? 60))
        let code = result.timedOut ? 124 : Int(result.status)
        try finishWork(id: row.id, output: result.output, code: code, sha: nil)
        try rememberArtifact(taskId: row.taskId, id: row.id, stageId: row.stageId, kind: "hook", text: result.output, at: at)
        try remember(taskId: row.taskId, line: "stage \(row.taskId) hook \(row.stageId) \(row.kind) \(code)")
        _ = at
        return true
    }

    private func runGateEffect(owner: String, at: Date) throws -> Bool {
        for item in try pendingEffectItems() {
            guard case .runGates(_, let commands) = item.effect else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, leaseFor: 30, at: at) else { continue }
            let task = try database.read { db in try Self.task(item.taskId, db: db) }
            let entry = try database.read { db in try Int.fetchOne(db, sql: "SELECT entry FROM stage_entry WHERE task_id = ?", arguments: [item.taskId.rawValue]) ?? 1 }
            // One row per effect: a later attempt of the same stage entry runs the gates again.
            // Replay of this effect finds the row and does not spawn.
            let workId = "\(item.taskId.rawValue)/\(entry)/gate/\(item.id)"
            let cached = try workRows("SELECT * FROM stage_work WHERE id = ?", StatementArguments([workId])).first
            if let cached, cached.status == "running" || cached.status == "finished" {
                let code = cached.code
                let output = cached.output
                if cached.status == "running" { try finishWork(id: workId, output: output, code: code == 0 ? 1 : code, sha: nil) }
                let outcome: RealEffectOutcome = code == 0 && cached.status == "finished" ? .gatesPassed : .gatesFailed(output: output)
                _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: lease.effectId + "/gates", phase: .finished, outcome: outcome), at: at, diagnostic: "BE-11 gate replay does not run the commands again")
                try remember(taskId: item.taskId.rawValue, line: "stage \(item.taskId.rawValue) gate \(task.machine.stageId.rawValue) replay")
                return true
            }
            guard let clone = try readyClone(item.taskId) else {
                _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: lease.effectId + "/gates", phase: .finished, outcome: .gatesFailed(output: "clone is not ready")), at: at, diagnostic: "BE-11 gate has no clone")
                return true
            }
            try insertWork(id: workId, taskId: item.taskId.rawValue, entry: entry, stageId: task.machine.stageId.rawValue, kind: "gate", command: commands.joined(separator: "\n"), effectId: lease.effectId)
            try database.write { db in
                try db.execute(sql: "UPDATE stage_work SET status = 'running' WHERE id = ?", arguments: [workId])
            }
            let stage = task.pipeline.stage(task.machine.stageId)
            var combined = ""
            var failed = false
            for command in commands {
                let result = try StageCommand.run(command: command, cwd: clone.clonePath, environment: StageCommand.environment(stage: stage?.agent?.env ?? [:]), timeout: TimeInterval(stage?.timeouts.wallSeconds ?? 60))
                combined = Self.cap(combined + "$ \(command)\n\(result.output)\n")
                if result.timedOut || result.status != 0 {
                    failed = true
                    break
                }
            }
            let code = failed ? 1 : 0
            try finishWork(id: workId, output: combined, code: code, sha: nil)
            if !combined.isEmpty {
                try rememberArtifact(taskId: item.taskId.rawValue, id: workId + "/output", stageId: task.machine.stageId.rawValue, kind: "gate_output", text: combined, at: at)
            }
            let outcome: RealEffectOutcome = failed ? .gatesFailed(output: combined) : .gatesPassed
            _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: lease.effectId + "/gates", phase: .finished, outcome: outcome), at: at, diagnostic: "BE-11 gate commands; a green process exit is not this result")
            try remember(taskId: item.taskId.rawValue, line: "stage \(item.taskId.rawValue) gate \(task.machine.stageId.rawValue) \(failed ? "failed" : "passed")")
            return true
        }
        return false
    }

    private func runResultEffect(owner: String, at: Date) throws -> Bool {
        for item in try pendingEffectItems() {
            guard case .runResultCheck = item.effect else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, leaseFor: 30, at: at) else { continue }
            let task = try database.read { db in try Self.task(item.taskId, db: db) }
            let stage = task.pipeline.stage(task.machine.stageId)
            let readOnly = stage?.isReadOnly == true
            let clone = try readyClone(item.taskId)
            let dirty = readOnly && clone != nil && ((try? TaskClone.worktreeDirty(clone!.clonePath, identity: try projectIdentity(task))) ?? true)
            let outcome: RealEffectOutcome = dirty ? .readOnlyChanges : .clean
            _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: lease.effectId + "/result", phase: .finished, outcome: outcome), at: at, diagnostic: "BE-11 result check reads the worktree; suspicious files stay BE-13")
            try remember(taskId: item.taskId.rawValue, line: "stage \(item.taskId.rawValue) result \(task.machine.stageId.rawValue) \(dirty ? "readonly" : "clean")")
            return true
        }
        return false
    }

    private func runCommit(owner: String, at: Date) throws -> Bool {
        for item in try pendingEffectItems() {
            guard case .commitStage = item.effect else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, leaseFor: 30, at: at) else { continue }
            let row = try workRows("SELECT * FROM stage_work WHERE effect_id = ? AND kind = 'commit'", StatementArguments([item.id])).first
            guard let row else {
                _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: lease.effectId + "/commit", phase: .finished, outcome: .acknowledged), at: at, diagnostic: "BE-11 commit had no stage entry")
                return true
            }
            if row.status == "finished" {
                _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: lease.effectId + "/commit", phase: .finished, outcome: .acknowledged), at: at, diagnostic: "BE-11 commit replay")
                try remember(taskId: row.taskId, line: "stage \(row.taskId) commit \(row.stageId) replay")
                return true
            }
            let task = try database.read { db in try Self.task(item.taskId, db: db) }
            let identity = try projectIdentity(task)
            let marker = TaskClone.effectMarkerPrefix + row.id
            if row.status == "pending" {
                try database.write { db in
                    try db.execute(sql: "UPDATE stage_work SET status = 'running' WHERE id = ? AND status = 'pending'", arguments: [row.id])
                }
            }
            var sha = row.sha
            if let clone = try readyClone(item.taskId) {
                sha = try TaskClone.commitMarked(clone: clone.clonePath, message: row.command, marker: marker, identity: identity)
                let base = clone.baseCommit ?? ""
                let stat = (try? TaskClone.diffstat(clone: clone.clonePath, from: base, identity: identity)) ?? ""
                let subjects = (try? TaskClone.commitSubjects(clone: clone.clonePath, from: base, identity: identity)) ?? ""
                try rememberArtifact(taskId: row.taskId, id: row.id + "/diffstat", stageId: row.stageId, kind: "diffstat", text: stat, at: at)
                try rememberArtifact(taskId: row.taskId, id: row.id + "/commits", stageId: row.stageId, kind: "commits", text: subjects, at: at)
            }
            try finishWork(id: row.id, output: row.command, code: 0, sha: sha)
            _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: lease.effectId + "/commit", phase: .finished, outcome: .acknowledged), at: at, diagnostic: "BE-11 one stage commit; replay finds the marker")
            try remember(taskId: row.taskId, line: "stage \(row.taskId) commit \(row.stageId) \(sha ?? "clean")")
            return true
        }
        return false
    }

    private func runRollback(owner: String, at: Date) throws -> Bool {
        for item in try pendingEffectItems() {
            guard case .saveWipAndRollback(let runId) = item.effect else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, leaseFor: 30, at: at) else { continue }
            if let clone = try readyClone(item.taskId) {
                let task = try database.read { db in try Self.task(item.taskId, db: db) }
                let project = try database.read { db in try Self.project(task.card.projectId, db: db) }
                if let ref = try TaskClone.saveWipAndReset(clone: clone.clonePath, runId: runId, recorded: clone.clonePath, workspaceRoot: clone.workspaceRoot, origin: clone.projectPath, identity: project.summary.identity) {
                    try database.write { db in
                        var detail = try Self.detail(item.taskId, db: db)
                        if let index = detail.runs.firstIndex(where: { $0.id == runId }) { detail.runs[index].wipRef = ref }
                        try Self.saveDetail(detail, taskId: item.taskId, db: db)
                    }
                }
            }
            _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: lease.effectId + "/rollback", phase: .finished, outcome: .acknowledged), at: at, diagnostic: "BE-11 read-only rollback uses the clone facts")
            try remember(taskId: item.taskId.rawValue, line: "stage \(item.taskId.rawValue) rollback \(runId.rawValue)")
            return true
        }
        return false
    }

    private struct ReadyClone {
        var clonePath: String
        var workspaceRoot: String
        var projectPath: String
        var baseCommit: String?
    }

    private func readyClone(_ taskId: TaskID) throws -> ReadyClone? {
        try database.read { db in
            guard let record = try Self.cloneRecord(taskId, db: db), record.phase == "ready" else { return nil }
            guard FileManager.default.fileExists(atPath: record.clonePath) else { return nil }
            return ReadyClone(clonePath: record.clonePath, workspaceRoot: record.workspaceRoot, projectPath: record.projectPath, baseCommit: record.baseCommit)
        }
    }

    private func projectIdentity(_ task: DurableTask) throws -> GitIdentity? {
        try database.read { db in try Self.project(task.card.projectId, db: db).summary.identity }
    }

    private func finishWork(id: String, output: String, code: Int, sha: String?) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE stage_work SET status = 'finished', output = ?, code = ?, sha = ? WHERE id = ?", arguments: [Self.cap(output), code, sha, id])
        }
    }

    private func rememberArtifact(taskId: String, id: String, stageId: String, kind: String, text: String, at: Date) throws {
        try database.write { db in
            var detail = try Self.detail(TaskID(rawValue: taskId), db: db)
            let artifact = ArtifactID(rawValue: id)
            guard !detail.artifacts.contains(where: { $0.id == artifact }) else { return }
            detail.artifacts.append(TaskArtifact(id: artifact, taskId: TaskID(rawValue: taskId), runId: nil, stageId: StageID(rawValue: stageId), kind: kind, text: Self.cap(text), createdAt: at))
            try Self.saveDetail(detail, taskId: TaskID(rawValue: taskId), db: db)
        }
    }

    private static func insertWork(id: String, taskId: String, entry: Int, stageId: String, kind: String, command: String, effectId: String?, db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO stage_work(id, task_id, entry, stage_id, kind, command, status, output, code, effect_id)
            VALUES (?, ?, ?, ?, ?, ?, 'pending', '', 0, ?)
            """, arguments: [id, taskId, entry, stageId, kind, command, effectId])
    }

    private func insertWork(id: String, taskId: String, entry: Int, stageId: String, kind: String, command: String, effectId: String?) throws {
        try database.write { db in
            try Self.insertWork(id: id, taskId: taskId, entry: entry, stageId: stageId, kind: kind, command: command, effectId: effectId, db: db)
        }
    }

    private static func commitMessage(_ commit: StageCommit, stage: StageID, task: TaskID) -> String {
        switch commit {
        case .daemonSingle(let summary):
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "kaban: \(stage.rawValue) \(task.rawValue)" : trimmed
        case .safety:
            return "kaban: \(stage.rawValue) \(task.rawValue)"
        }
    }

    private static func cap(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > StageCommand.outputLimit else { return text }
        return String(decoding: bytes.prefix(StageCommand.outputLimit), as: UTF8.self)
    }
}
