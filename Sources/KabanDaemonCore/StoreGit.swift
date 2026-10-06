import Foundation
import GRDB
import KabanKit
import KabanProtocol

struct GitCheckReply: Equatable, Sendable {
    var allow: Bool
    var message: String
    var rule: String
}

extension KabanStore {
    static func migrateGitPolicy(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE git_policy_extra (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            stage_id TEXT,
            rule TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)
    }

    /// One argv check. A grant is consumed in this same write, or not at all.
    /// A missing token is a denial and does not authorize the command.
    func checkGit(token: String, argv: [String], at: Date) throws -> GitCheckReply {
        projectOperations.lock(); defer { projectOperations.unlock() }
        return try database.write { db in try Self.checkGit(token: token, argv: argv, at: at, db: db) }
    }

    static func checkGit(token: String, argv: [String], at: Date, db: Database) throws -> GitCheckReply {
        guard let row = try tokenRow(SHA256Digest.hex(token), db: db), !row.revoked else { return denied("unauthorized") }
        let taskId = TaskID(rawValue: row.taskId)
        let task = try task(taskId, db: db)
        let run = RunID(rawValue: row.runId)
        let live = task.machine.state == .running && task.machine.currentRunId == run && task.machine.stageId.rawValue == row.stageId
        guard live else { return denied("unauthorized") }
        guard !argv.isEmpty, argv.count <= 32, argv.allSatisfy({ $0.utf8.count <= 4_096 }) else { return denied("invalid") }
        let words = GitCheck.normalize(argv: argv)
        let command = words.joined(separator: " ")
        guard !command.isEmpty else { return denied("invalid") }
        guard let stage = task.pipeline.stage(task.machine.stageId) else { return try deny(task, run: run, argv: argv, rule: "policy", at: at, db: db) }
        if let id = GitCheck.blocked(words) {
            return try deny(task, run: run, argv: argv, rule: id, at: at, db: db)
        }
        let policy = GitPolicyResolver.resolve(project: task.pipeline.git, stage: stage)
        if policy.allows(command, returnReason: task.machine.returnReason) {
            return GitCheckReply(allow: true, message: "", rule: "policy")
        }
        let detail = try detail(taskId, db: db)
        if let extra = try extraDeny(command, project: task.card.projectId, stage: task.machine.stageId, startedAt: detail.runs.first { $0.id == run }?.startedAt, db: db) {
            return try deny(task, run: run, argv: argv, rule: extra, at: at, db: db)
        }
        if let index = detail.gitGrants.firstIndex(where: {
            $0.taskId == taskId && $0.stageId == task.machine.stageId && GitCheck.sameCommand($0.grant.argv, argv)
                && $0.consumption == nil && $0.revocation == nil && $0.expiry == nil
        }) {
            var updated = detail
            let ref = GitGrantRef(grantId: updated.gitGrants[index].grant.grantId, runId: run)
            updated.gitGrants[index].consumption = ref
            updated.gitGrants[index].consumedAt = at
            try saveDetail(updated, taskId: taskId, db: db)
            _ = try journal(.gitGrantConsumed(ref), task: task, commandId: UUID(), at: at, db: db)
            return GitCheckReply(allow: true, message: "", rule: "grant")
        }
        let rule = policy.denied.first { GitPolicyResolver.covers($0.rule, command) }?.rule
            ?? (GitPolicyResolver.isKnown(command) ? "policy" : "unknown")
        return try deny(task, run: run, argv: argv, rule: rule, at: at, db: db)
    }

    static func allowGitOnce(_ denialId: DenialID, commandId: CommandID, at: Date, db: Database) throws -> Seq {
        guard let found = try findDenial(denialId, db: db) else {
            throw StoreError.rejected(CommandError(code: CommandError.notFoundCode, message: "Отказ не найден."))
        }
        guard try isManaged(found.taskId, db: db) else { throw StoreError.incompleteProjection }
        var task = try task(found.taskId, db: db)
        var detail = try detail(found.taskId, db: db)
        if detail.gitGrants.contains(where: { $0.grant.denialId == denialId }) { return try seq(db) }
        let words = GitCheck.normalize(argv: found.denial.denial.argv)
        if let id = GitCheck.blocked(words) {
            throw StoreError.rejected(CommandError(code: "git_hard_invariant", message: "Жёсткий инвариант нельзя разрешить.", params: ["rule": id]))
        }
        let grant = GitGrantCreated(grantId: GrantID(rawValue: "grant-\(UUID().uuidString.lowercased())"), denialId: denialId, argv: found.denial.denial.argv, by: .human)
        detail.gitGrants.append(GitGrantSnapshot(grant: grant, taskId: found.taskId, stageId: task.machine.stageId, createdAt: at))
        try saveDetail(detail, taskId: found.taskId, db: db)
        task.card.updatedAt = at
        try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try encode(task), found.taskId.rawValue])
        return try journal(.gitGrantCreated(grant), task: task, commandId: commandId, at: at, db: db)
    }

    static func addDenialToPolicy(_ denialId: DenialID, scope: PolicyScope, commandId: CommandID, at: Date, db: Database) throws -> Seq {
        guard let found = try findDenial(denialId, db: db) else {
            throw StoreError.rejected(CommandError(code: CommandError.notFoundCode, message: "Отказ не найден."))
        }
        let task = try task(found.taskId, db: db)
        guard try isManaged(found.taskId, db: db) else { throw StoreError.incompleteProjection }
        let rule = GitCheck.normalize(argv: found.denial.denial.argv).joined(separator: " ")
        guard !rule.isEmpty else { throw StoreError.rejected(CommandError(code: "invalid_request", message: "В отказе нет команды.")) }
        let stage: String? = switch scope {
        case .project: nil
        case .stage(let id): id.rawValue
        }
        try db.execute(sql: "INSERT OR IGNORE INTO git_policy_extra(id, project_id, stage_id, rule, created_at) VALUES (?, ?, ?, ?, ?)", arguments: [
            denialId.rawValue, task.card.projectId.rawValue, stage, rule, at.timeIntervalSince1970,
        ])
        // A row created while a run is already going does not change that run. The YAML autocommit
        // stays with updatePipeline; this table is what the next run's /git/check reads.
        guard db.changesCount == 1 else { return try seq(db) }
        let version = task.pipelineVersion ?? "extra"
        return try journal(.gitPolicyUpdated(GitPolicyUpdated(projectId: task.card.projectId, scope: scope, pipelineVersion: version)), task: task, commandId: commandId, at: at, db: db)
    }

    static func revokeGitGrant(_ grantId: GrantID, commandId: CommandID, at: Date, db: Database) throws -> Seq {
        guard let found = try findGrant(grantId, db: db) else {
            throw StoreError.rejected(CommandError(code: CommandError.notFoundCode, message: "Разрешение не найдено."))
        }
        guard try isManaged(found.taskId, db: db) else { throw StoreError.incompleteProjection }
        if found.detail.gitGrants[found.index].revocation != nil { return try seq(db) }
        var detail = found.detail
        let revoked = GitGrantRevoked(grantId: grantId, by: .human)
        detail.gitGrants[found.index].revocation = revoked
        detail.gitGrants[found.index].revokedAt = at
        try saveDetail(detail, taskId: found.taskId, db: db)
        let task = try task(found.taskId, db: db)
        return try journal(.gitGrantRevoked(revoked), task: task, commandId: commandId, at: at, db: db)
    }

    /// Grants end with the task. The argv stays on the snapshot. Idempotent when a grant is already expired.
    static func expireGitGrants(in effects: [TaskEffect], task: DurableTask, commandId: CommandID, at: Date, db: Database) throws {
        let reason = effects.compactMap { effect -> GitGrantExpiryReason? in
            if case .expireGitGrants(let reason) = effect { return reason }
            return nil
        }.first
        guard let reason, let data = try Data.fetchOne(db, sql: "SELECT payload FROM task_detail WHERE task_id = ?", arguments: [task.card.id.rawValue]) else { return }
        var detail = try decode(StoredDetail.self, data)
        var changed = false
        for index in detail.gitGrants.indices where detail.gitGrants[index].expiry == nil {
            let expired = GitGrantExpired(grantId: detail.gitGrants[index].grant.grantId, reason: reason)
            detail.gitGrants[index].expiry = expired
            detail.gitGrants[index].expiredAt = at
            _ = try journal(.gitGrantExpired(expired), task: task, commandId: commandId, at: at, db: db)
            changed = true
        }
        if changed { try saveDetail(detail, taskId: task.card.id, db: db) }
    }

    private static func denied(_ rule: String) -> GitCheckReply {
        GitCheckReply(allow: false, message: GitCheck.deniedMessage, rule: rule)
    }

    private static func deny(_ task: DurableTask, run: RunID, argv: [String], rule: String, at: Date, db: Database) throws -> GitCheckReply {
        var detail = try detail(task.card.id, db: db)
        let denial = GitDenied(denialId: DenialID(rawValue: "denial-\(UUID().uuidString.lowercased())"), taskId: task.card.id, runId: run, argv: argv, rule: rule)
        detail.gitDenials.append(GitDenialSnapshot(denial: denial, at: at))
        try saveDetail(detail, taskId: task.card.id, db: db)
        _ = try journal(.gitDenied(denial), task: task, commandId: UUID(), at: at, db: db)
        if detail.gitDenials.filter({ $0.denial.runId == run }).count >= 5 {
            let command = DurableTaskCommand.gitDenialLimit(run)
            let commandId = UUID()
            let request = try encode(Request(kind: "transition", taskId: task.card.id, body: encode(command)))
            _ = try apply(command, taskId: task.card.id, commandId: commandId, at: at, request: request, db: db)
        }
        return denied(rule)
    }

    private static func extraDeny(_ command: String, project: ProjectID, stage: StageID, startedAt: Date?, db: Database) throws -> String? {
        for row in try Row.fetchAll(db, sql: "SELECT stage_id, rule, created_at FROM git_policy_extra WHERE project_id = ?", arguments: [project.rawValue]) {
            let bound: String? = row["stage_id"]
            if let bound, bound != stage.rawValue { continue }
            let created = Date(timeIntervalSince1970: createdAt(row))
            guard let startedAt, startedAt >= created else { continue }
            let rule: String = row["rule"]
            if GitPolicyResolver.covers(rule, command) { return rule }
        }
        return nil
    }

    private static func createdAt(_ row: Row) -> Double {
        if let value = Double.fromDatabaseValue(row["created_at"]) { return value }
        if let value = Int64.fromDatabaseValue(row["created_at"]) { return Double(value) }
        return .greatestFiniteMagnitude
    }

    private struct LocatedDenial {
        var taskId: TaskID
        var denial: GitDenialSnapshot
    }

    private static func findDenial(_ id: DenialID, db: Database) throws -> LocatedDenial? {
        for row in try Row.fetchAll(db, sql: "SELECT task_id, payload FROM task_detail") {
            let detail = try decode(StoredDetail.self, row["payload"])
            if let denial = detail.gitDenials.first(where: { $0.denial.denialId == id }) {
                return LocatedDenial(taskId: TaskID(rawValue: row["task_id"]), denial: denial)
            }
        }
        return nil
    }

    private struct LocatedGrant {
        var taskId: TaskID
        var detail: StoredDetail
        var index: Int
    }

    private static func findGrant(_ id: GrantID, db: Database) throws -> LocatedGrant? {
        for row in try Row.fetchAll(db, sql: "SELECT task_id, payload FROM task_detail") {
            let detail = try decode(StoredDetail.self, row["payload"])
            if let index = detail.gitGrants.firstIndex(where: { $0.grant.grantId == id }) {
                return LocatedGrant(taskId: TaskID(rawValue: row["task_id"]), detail: detail, index: index)
            }
        }
        return nil
    }
}
