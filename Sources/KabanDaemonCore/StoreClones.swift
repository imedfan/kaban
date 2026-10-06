import Foundation
import GRDB
import KabanKit
import KabanProtocol

public struct TaskCloneReservation: Equatable, Sendable {
    public var clonePath: String
    public var freshPath: String?
    public var branch: String
}

public struct TaskCloneSnapshot: Equatable, Sendable {
    public var taskId: TaskID
    public var branch: String
    public var clonePath: String
    public var freshPath: String?
    public var baseCommit: String
    public var portStart: Int
    public var portEnd: Int
    public var derivedDataPath: String
    public var tempPath: String
    public var passLines: [String]
}

extension KabanStore {
    static func migrateTaskClones(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE task_clone (task_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
    }

    /// Commits the clone path before git runs. A second call keeps the same path.
    public func reserveTaskClone(taskId: TaskID, at: Date, workspaceRoot: String) throws -> TaskCloneReservation {
        try database.write { db in
            if let record = try Self.cloneRecord(taskId, db: db) {
                return TaskCloneReservation(clonePath: record.clonePath, freshPath: record.freshPath, branch: record.branch)
            }
            let record = try Self.makeCloneRecord(taskId, workspaceRoot: workspaceRoot, db: db)
            try db.execute(sql: "INSERT INTO task_clone(task_id, payload) VALUES (?, ?)", arguments: [taskId.rawValue, try Self.encode(record)])
            _ = at
            return TaskCloneReservation(clonePath: record.clonePath, freshPath: record.freshPath, branch: record.branch)
        }
    }

    /// Creates the reserved clone outside the SQLite transaction. A partial directory is removed only after the path check and is never replaced with a second path.
    public func prepareTaskClone(taskId: TaskID, at: Date, workspaceRoot: String) throws -> TaskCloneSnapshot {
        let reserved = try reserveTaskClone(taskId: taskId, at: at, workspaceRoot: workspaceRoot)
        let context = try database.read { db -> (TaskCloneRecord, GitIdentity?) in
            let record = try Self.cloneRecord(taskId, db: db)!
            let project = try Self.project(try Self.task(taskId, db: db).card.projectId, db: db)
            return (record, project.summary.identity)
        }
        var record = context.0
        let plan = record.plan
        if record.phase == "ready", TaskClone.taskReady(plan, identity: context.1), TaskClone.freshReady(plan, identity: context.1) {
            return record.snapshot
        }
        if FileManager.default.fileExists(atPath: plan.clonePath), !TaskClone.taskReady(plan, identity: context.1) {
            try TaskClone.removeAuthorized(plan.clonePath, recorded: plan.clonePath, workspaceRoot: record.workspaceRoot, origin: record.projectPath)
        }
        if !TaskClone.taskReady(plan, identity: context.1) {
            try TaskClone.materialize(plan, origin: record.projectPath, workspaceRoot: record.workspaceRoot, identity: context.1, fresh: false)
        }
        if plan.freshPath != nil, !TaskClone.freshReady(plan, identity: context.1) {
            try TaskClone.materialize(plan, origin: record.projectPath, workspaceRoot: record.workspaceRoot, identity: context.1, fresh: true)
        }
        let base = try TaskClone.head(plan.clonePath, identity: context.1)
        record.phase = "ready"
        record.baseCommit = base
        record.passLines = ["clone ready \(taskId.rawValue) branch \(record.branch)", "clone origin-clean \(taskId.rawValue)"]
        _ = reserved
        return try database.write { db in
            var task = try Self.task(taskId, db: db)
            task.card.branch = record.branch
            task.card.updatedAt = at
            try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try Self.encode(task), taskId.rawValue])
            var detail = try Self.detail(taskId, db: db)
            detail.clonePath = record.clonePath
            let feedId = taskId.rawValue + "/clone"
            if !detail.feed.contains(where: { $0.id == feedId }) {
                detail.feed.append(FeedItem(id: feedId, at: at, kind: "clone", text: "Task clone ready", runId: task.machine.lastRunId))
            }
            try Self.saveDetail(detail, taskId: taskId, db: db)
            try db.execute(sql: "UPDATE task_clone SET payload = ? WHERE task_id = ?", arguments: [try Self.encode(record), taskId.rawValue])
            _ = try Self.journal(.taskUpdated(task.card), task: task, commandId: UUID(), at: at, db: db)
            return record.snapshot
        }
    }

    /// Archives according to `keepBranch`, then deletes only the recorded clone. Git work happens after the claim commit and before the receipt.
    @discardableResult
    public func cleanupTaskClone(effectId: String, owner: String, at: Date) throws -> EffectReceipt {
        if let existing = try acknowledgedCloneReceipt(effectId) { return existing }
        guard let lease = try claimEffect(id: effectId, owner: owner, leaseFor: 30, at: at) else { throw StoreError.effectMissing }
        guard case .cleanupClone(let keepBranch) = lease.payload.effect else { throw StoreError.unsupportedEffect }
        let taskId = lease.payload.taskId
        let record = try database.read { db in try Self.cloneRecord(taskId, db: db) }
        if let record, record.phase == "ready" {
            try TaskClone.authorizeDeletion(candidate: record.clonePath, recorded: record.clonePath, workspaceRoot: record.workspaceRoot, origin: record.projectPath)
            if let fresh = record.freshPath {
                try TaskClone.authorizeDeletion(candidate: fresh, recorded: fresh, workspaceRoot: record.workspaceRoot, origin: record.projectPath)
            }
            let project = try database.read { db in try Self.project(try Self.task(taskId, db: db).card.projectId, db: db) }
            if keepBranch, FileManager.default.fileExists(atPath: record.clonePath) {
                try TaskClone.archiveTip(record.plan, taskId: taskId, origin: record.projectPath, identity: project.summary.identity)
            }
            try TaskClone.removeAuthorized(record.clonePath, recorded: record.clonePath, workspaceRoot: record.workspaceRoot, origin: record.projectPath)
            if let fresh = record.freshPath {
                try TaskClone.removeAuthorized(fresh, recorded: fresh, workspaceRoot: record.workspaceRoot, origin: record.projectPath)
            }
            try database.write { db in
                var removed = record
                removed.phase = "removed"
                var detail = try Self.detail(taskId, db: db)
                detail.clonePath = nil
                try Self.saveDetail(detail, taskId: taskId, db: db)
                try db.execute(sql: "UPDATE task_clone SET payload = ? WHERE task_id = ?", arguments: [try Self.encode(removed), taskId.rawValue])
            }
        }
        let fact = ExternalEffectFact(actionId: effectId + "/clone", phase: .finished, outcome: .acknowledged)
        return try commitEffectResult(effectId: effectId, leaseId: lease.leaseId, fact: fact, at: at, diagnostic: "BE-06 clone cleanup; archive follows keepBranch; foreign paths are not deleted")
    }

    /// Reprints ready clones and performs pending cleanup. Agent runs are not started or completed here.
    public func runClonePass(owner: String, at: Date, workspaceRoot: String) throws -> [String] {
        let running = try database.read { db in try Self.allTasks(db).filter { if case .running = $0.machine.state { true } else { false } }.map(\.card.id) }
        for taskId in running where try database.read({ db in try Self.cloneRecord(taskId, db: db)?.phase }) != "ready" {
            _ = try prepareTaskClone(taskId: taskId, at: at, workspaceRoot: workspaceRoot)
        }
        let cleanups: [(String, Bool)] = try database.read { db in
            var found: [(String, Bool)] = []
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM effect WHERE status = 'pending' ORDER BY rowid") {
                let pending = try Self.decode(PendingEffect.self, row["payload"])
                if case .cleanupClone(let keep) = pending.effect { found.append((row["id"], keep)) }
            }
            return found
        }
        for item in cleanups {
            _ = try cleanupTaskClone(effectId: item.0, owner: owner, at: at)
        }
        return try database.read { db in
            var lines: [String] = []
            for row in try Row.fetchAll(db, sql: "SELECT payload FROM task_clone ORDER BY task_id") {
                let record = try Self.decode(TaskCloneRecord.self, row["payload"])
                if record.phase == "ready" { lines.append(contentsOf: record.passLines) }
                if record.phase == "removed" { lines.append("clone removed \(record.taskId.rawValue)") }
            }
            return lines
        }
    }

    private func acknowledgedCloneReceipt(_ effectId: String) throws -> EffectReceipt? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT status, receipt FROM effect WHERE id = ?", arguments: [effectId]) else { return nil }
            guard (row["status"] as String) == "acknowledged", let receipt: Data = row["receipt"] else { return nil }
            return try Self.decode(EffectReceipt.self, receipt)
        }
    }

    private static func makeCloneRecord(_ taskId: TaskID, workspaceRoot: String, db: Database) throws -> TaskCloneRecord {
        let task = try task(taskId, db: db)
        let project = try project(task.card.projectId, db: db)
        let fresh = task.pipeline.stage(task.machine.stageId)?.agent?.workspace == .freshReadonly
        let planned = try TaskClone.plan(taskId: taskId, title: task.card.title, projectId: task.card.projectId, stageId: task.machine.stageId, fresh: fresh, workspaceRoot: workspaceRoot)
        return TaskCloneRecord(taskId: taskId, projectPath: project.summary.path, workspaceRoot: standardizeCloneRoot(workspaceRoot),
                               clonePath: planned.clonePath, freshPath: planned.freshPath, branch: planned.branch, phase: "preparing",
                               baseCommit: nil, portStart: planned.portStart, portEnd: planned.portEnd, derivedDataPath: planned.derivedDataPath,
                               tempPath: planned.tempPath, passLines: [])
    }

    static func cloneRecord(_ taskId: TaskID, db: Database) throws -> TaskCloneRecord? {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM task_clone WHERE task_id = ?", arguments: [taskId.rawValue]) else { return nil }
        return try decode(TaskCloneRecord.self, data)
    }

    private static func standardizeCloneRoot(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

struct TaskCloneRecord: Codable, Equatable {
    var taskId: TaskID
    var projectPath: String
    var workspaceRoot: String
    var clonePath: String
    var freshPath: String?
    var branch: String
    var phase: String
    var baseCommit: String?
    var portStart: Int
    var portEnd: Int
    var derivedDataPath: String
    var tempPath: String
    var passLines: [String]

    var plan: TaskClone.Plan {
        .init(clonePath: clonePath, freshPath: freshPath, branch: branch, derivedDataPath: derivedDataPath, tempPath: tempPath, portStart: portStart, portEnd: portEnd)
    }

    var snapshot: TaskCloneSnapshot {
        .init(taskId: taskId, branch: branch, clonePath: clonePath, freshPath: freshPath, baseCommit: baseCommit ?? "", portStart: portStart, portEnd: portEnd,
              derivedDataPath: derivedDataPath, tempPath: tempPath, passLines: passLines)
    }
}
