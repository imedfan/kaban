import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    static func migrateEngine(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE project (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE global_settings (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE configuration_command (id TEXT PRIMARY KEY NOT NULL, request BLOB NOT NULL, receipt BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE task_detail (task_id TEXT PRIMARY KEY NOT NULL REFERENCES task(id), payload BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE task_admission (task_id TEXT PRIMARY KEY NOT NULL REFERENCES task(id), project_id TEXT NOT NULL REFERENCES project(id), created_seq INTEGER NOT NULL, queue_seq INTEGER NOT NULL)")
        try db.execute(sql: "CREATE TABLE human_admission (task_id TEXT PRIMARY KEY NOT NULL REFERENCES task(id), stage_id TEXT NOT NULL)")
        try db.execute(sql: "CREATE TABLE effect (id TEXT PRIMARY KEY NOT NULL, command_id TEXT NOT NULL, task_id TEXT NOT NULL REFERENCES task(id), ordinal INTEGER NOT NULL, payload BLOB NOT NULL, status TEXT NOT NULL, result BLOB, receipt BLOB)")
        try db.execute(sql: "CREATE INDEX effect_pending ON effect(status, task_id)")
        try db.execute(sql: "CREATE TABLE tick (id TEXT PRIMARY KEY NOT NULL, receipt BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE scheduler_cursor (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL)")
        try db.execute(sql: "INSERT INTO scheduler_cursor(id, payload) VALUES (1, ?)", arguments: [try encode(SchedulerCursor())])
        // v1 payloads stay untouched. Import exact pending payloads once; don't recompute reducer output.
        for data in try Data.fetchAll(db, sql: "SELECT payload FROM effect_outbox ORDER BY rowid") {
            try enqueue(decode(PendingEffectBatch.self, data), db: db)
        }
    }
    static func enqueue(_ batch: PendingEffectBatch, db: Database) throws {
        for (index, effect) in batch.effects.enumerated() {
            let id = "\(batch.commandId.uuidString.lowercased())/\(index)"
            let pending = PendingEffect(version: batch.version, id: id, commandId: batch.commandId, taskId: batch.taskId, index: index, effect: effect)
            try db.execute(sql: "INSERT INTO effect(id, command_id, task_id, ordinal, payload, status) VALUES (?, ?, ?, ?, ?, 'pending')",
                           arguments: [id, batch.commandId.uuidString.lowercased(), batch.taskId.rawValue, index, try encode(pending)])
        }
    }
    static func supersedeEffects(taskId: TaskID, db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, payload FROM effect WHERE task_id = ? AND status = 'pending'", arguments: [taskId.rawValue])
        for row in rows {
            let pending = try decode(PendingEffect.self, row["payload"])
            switch pending.effect {
            case .startAgentRun, .runGates, .runResultCheck, .startMerge, .fastForwardMerge, .scheduleRetry:
                try db.execute(sql: "UPDATE effect SET status = 'superseded' WHERE id = ?", arguments: [row["id"] as String])
            default: break
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM effect_outbox WHERE task_id = ?", arguments: [taskId.rawValue]) {
            let batch = try decode(PendingEffectBatch.self, row["payload"])
            let remaining = try batch.effects.enumerated().filter { index, _ in
                try String.fetchOne(db, sql: "SELECT status FROM effect WHERE id = ?", arguments: ["\(batch.commandId.uuidString.lowercased())/\(index)"]) == "pending"
            }.map(\.element)
            if remaining.isEmpty { try db.execute(sql: "DELETE FROM effect_outbox WHERE id = ?", arguments: [row["id"] as String]) }
        }
    }
    static func createDetail(_ task: DurableTask, at: Date, db: Database) throws {
        try db.execute(sql: "INSERT INTO task_detail(task_id, payload) VALUES (?, ?)", arguments: [task.card.id.rawValue, try encode(StoredDetail())])
    }
    static func detail(_ id: TaskID, db: Database) throws -> StoredDetail {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM task_detail WHERE task_id = ?", arguments: [id.rawValue]) else { throw StoreError.incompleteProjection }
        return try decode(StoredDetail.self, data)
    }
    static func project(_ id: ProjectID, db: Database) throws -> ProjectRecord {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM project WHERE id = ?", arguments: [id.rawValue]) else { throw StoreError.projectMissing }
        return try decode(ProjectRecord.self, data)
    }
    static func settings(_ db: Database) throws -> GlobalSettings {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM global_settings WHERE id = 1") else { throw StoreError.incompleteProjection }
        return try decode(GlobalSettings.self, data)
    }
    static func isManaged(_ id: TaskID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM task_admission WHERE task_id = ?)", arguments: [id.rawValue]) == true
    }
    static func allTasks(_ db: Database) throws -> [DurableTask] {
        try Data.fetchAll(db, sql: "SELECT payload FROM task ORDER BY id").map { try decode(DurableTask.self, $0) }
    }
}
