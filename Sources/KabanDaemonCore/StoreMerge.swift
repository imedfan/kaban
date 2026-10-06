import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    static func migrateMergeIntent(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE merge_intent (
                task_id TEXT PRIMARY KEY NOT NULL,
                base_sha TEXT NOT NULL,
                tip_sha TEXT NOT NULL
            )
            """)
    }

    /// One project's merge at a time: rebase in a temporary clone, repeat gates and the result check, then fast-forward.
    /// A second call reprints the same lines. Git runs after the claim commit. A crash between the fast-forward
    /// and the receipt is reconciled from `refs/heads/main` and does not update the ref again. This is not exactly-once of git.
    public func runMergePass(owner: String, at: Date, workspaceRoot: String) throws -> [String] {
        for _ in 0..<24 {
            if try releaseCleanMain(at: at) { continue }
            if try rebaseOneMerge(owner: owner, at: at, workspaceRoot: workspaceRoot) { continue }
            if try runResultEffect(owner: owner, at: at) { continue }
            if try forwardOneMerge(owner: owner, at: at) { continue }
            break
        }
        return try stageLines()
    }

    struct MergeIntent { var base: String; var tip: String }

    func mergeIntent(_ taskId: TaskID) throws -> MergeIntent? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT base_sha, tip_sha FROM merge_intent WHERE task_id = ?", arguments: [taskId.rawValue]) else { return nil }
            return MergeIntent(base: row["base_sha"], tip: row["tip_sha"])
        }
    }

    /// Adopts a `main`-only ref move so a later dev result check does not roll back the commit the merge rebased onto.
    func acceptMainHead(_ task: DurableTask, identity: GitIdentity?) throws {
        let project = try database.read { db in try Self.project(task.card.projectId, db: db) }
        guard let snapshot = try database.read({ db in try Self.protectionSnapshot(project.summary.id, db: db) }) else { return }
        let current = try TaskClone.captureProtection(project.summary.path, identity: identity)
        var adopted = snapshot
        if let main = current.heads["refs/heads/main"] {
            adopted.heads["refs/heads/main"] = main
        } else {
            adopted.heads.removeValue(forKey: "refs/heads/main")
        }
        guard adopted.heads == current.heads, adopted.tags == current.tags, adopted.config == current.config else { return }
        guard adopted.heads != snapshot.heads else { return }
        try database.write { db in
            try Self.replaceProtectionSnapshot(adopted, projectId: project.summary.id, db: db)
        }
    }

    func rebaseOneMerge(owner: String, at: Date, workspaceRoot: String) throws -> Bool {
        for item in try pendingEffectItems() {
            guard case .startMerge(_, let gates) = item.effect else { continue }
            let task = try database.read { db in try Self.task(item.taskId, db: db) }
            if try mergeBusy(task) { continue }
            guard let clone = try readyClone(item.taskId) else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, leaseFor: 30, at: at) else { continue }
            let identity = try projectIdentity(task)
            try acceptMainHead(task, identity: identity)
            let requested = URL(fileURLWithPath: workspaceRoot).resolvingSymlinksInPath().standardizedFileURL.path
            let root = requested == clone.workspaceRoot ? requested : clone.workspaceRoot
            let rebase = try TaskClone.rebaseOntoMain(origin: clone.projectPath, clone: clone.clonePath, branch: clone.branch, workspaceRoot: root, taskId: item.taskId, identity: identity)
            if !rebase.conflicts.isEmpty {
                let fact = ExternalEffectFact(actionId: lease.effectId + "/merge", phase: .finished, outcome: .mergeConflict(rebase.conflicts))
                _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: fact, at: at, diagnostic: "BE-17 rebase conflict aborts the temporary clone and does not change the user checkout")
                try remember(taskId: item.taskId.rawValue, line: "merge \(item.taskId.rawValue) conflict")
                return true
            }
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO merge_intent(task_id, base_sha, tip_sha) VALUES (?, ?, ?)
                    ON CONFLICT(task_id) DO UPDATE SET base_sha = excluded.base_sha, tip_sha = excluded.tip_sha
                    """, arguments: [item.taskId.rawValue, rebase.base, rebase.tip])
            }
            let stage = task.pipeline.stage(task.machine.stageId)
            var combined = ""
            var failed = false
            for command in gates {
                let result = try runStageCommand(command: command, cwd: clone.clonePath, environment: StageCommand.environment(stage: stage?.agent?.env ?? [:]), timeout: TimeInterval(stage?.timeouts.wallSeconds ?? 60))
                combined += "$ \(command)\n\(result.output)\n"
                if result.timedOut || result.status != 0 { failed = true; break }
            }
            let outcome: RealEffectOutcome = failed ? .gatesFailed(output: combined) : .gatesPassed
            let fact = ExternalEffectFact(actionId: lease.effectId + "/merge", phase: .finished, outcome: outcome)
            _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: fact, at: at, diagnostic: "BE-17 rebase and gates; a green gate is not the fast-forward")
            if failed { try remember(taskId: item.taskId.rawValue, line: "merge \(item.taskId.rawValue) gates") }
            return true
        }
        return false
    }

    func forwardOneMerge(owner: String, at: Date) throws -> Bool {
        for item in try pendingEffectItems() {
            guard case .fastForwardMerge = item.effect else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, leaseFor: 30, at: at) else { continue }
            let fact = try prepareFastForward(lease: lease, at: at)
            _ = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: fact, at: at, diagnostic: "BE-17 fast-forward after the claim; a crash before this receipt is reconciled from git and does not merge twice")
            let line = try mergeLine(taskId: item.taskId, outcome: fact.outcome)
            try remember(taskId: item.taskId.rawValue, line: line)
            return true
        }
        return false
    }

    /// Claims nothing. Git runs here, then the finished fact is stored. `commitEffectResult` is a separate step,
    /// so a crash in between receipts the fact on recovery and does not fast-forward again when `main` is already `tip`.
    func prepareFastForward(lease: EffectLease, at: Date) throws -> ExternalEffectFact {
        let taskId = lease.payload.taskId
        let task = try database.read { db in try Self.task(taskId, db: db) }
        guard let clone = try readyClone(taskId) else { throw TaskClone.Failure.gitFailed }
        guard let intent = try mergeIntent(taskId) else { throw TaskClone.Failure.gitFailed }
        let identity = try projectIdentity(task)
        let origin = clone.projectPath
        let action = lease.effectId + "/merge"
        func finish(_ outcome: RealEffectOutcome) throws -> ExternalEffectFact {
            let fact = ExternalEffectFact(actionId: action, phase: .finished, outcome: outcome)
            try recordExternalFact(effectId: lease.effectId, leaseId: lease.leaseId, fact: fact)
            return fact
        }
        let main = try TaskClone.mainCommit(origin, identity: identity)
        if main == intent.tip { return try finish(.merged) }
        if main != intent.base { return try finish(.mainMoved) }
        let branch = try TaskClone.checkedOutBranch(origin, identity: identity)
        if branch == "main" {
            let dirty = try TaskClone.dirtyPaths(origin, identity: identity)
            let incoming = try TaskClone.diffNames(from: intent.base, to: intent.tip, in: clone.clonePath, identity: identity)
            if !Set(dirty).isDisjoint(with: incoming) { return try finish(.mainDirty) }
        }
        let ancestor = try TaskClone.rebaseAncestor(base: intent.base, tip: intent.tip, repository: clone.clonePath, identity: identity)
        guard ancestor else { return try finish(.mainMoved) }
        let judged = try judgeResult(task: task, clone: clone, identity: identity, readOnly: false, ignoringMainMove: true)
        if case .clean = judged.outcome {
            try TaskClone.fastForwardMain(origin: origin, clone: clone.clonePath, branch: clone.branch, tip: intent.tip, taskId: taskId, identity: identity)
            guard try TaskClone.mainCommit(origin, identity: identity) == intent.tip else { throw TaskClone.Failure.gitFailed }
            return try finish(.merged)
        }
        return try finish(judged.outcome)
    }

    func releaseCleanMain(at: Date) throws -> Bool {
        let tasks = try database.read { db in try Self.allTasks(db) }
        for task in tasks where task.machine.state == .blocked(.mainDirty) {
            guard let intent = try mergeIntent(task.card.id), let clone = try readyClone(task.card.id) else { continue }
            let identity = try projectIdentity(task)
            let branch = try TaskClone.checkedOutBranch(clone.projectPath, identity: identity)
            let dirty = try TaskClone.dirtyPaths(clone.projectPath, identity: identity)
            let incoming = try TaskClone.diffNames(from: intent.base, to: intent.tip, in: clone.clonePath, identity: identity)
            if branch == "main", !Set(dirty).isDisjoint(with: incoming) { continue }
            _ = try apply(.mainCleaned, taskId: task.card.id, commandId: UUID(), at: at)
            try remember(taskId: task.card.id.rawValue, line: "merge \(task.card.id.rawValue) cleaned")
            return true
        }
        return false
    }

    private func mergeBusy(_ task: DurableTask) throws -> Bool {
        try database.read { db in
            try Self.allTasks(db).contains { other in
                other.card.id != task.card.id && other.card.projectId == task.card.projectId
                    && other.pipeline.stage(other.machine.stageId)?.kind == .merge
                    && (other.machine.state.status == .gating || other.machine.state.status == .blocked)
            }
        }
    }

    private func mergeLine(taskId: TaskID, outcome: RealEffectOutcome?) throws -> String {
        switch outcome {
        case .merged:
            guard let tip = try mergeIntent(taskId)?.tip else { return "merge \(taskId.rawValue) ff" }
            return "merge \(taskId.rawValue) ff \(tip)"
        case .mainDirty: return "merge \(taskId.rawValue) dirty"
        case .mainMoved: return "merge \(taskId.rawValue) moved"
        case .mergeConflict: return "merge \(taskId.rawValue) conflict"
        default: return "merge \(taskId.rawValue) recheck"
        }
    }
}
