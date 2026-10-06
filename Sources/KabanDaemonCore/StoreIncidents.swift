import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    static func migrateIncidents(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE incident (
                id TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                resolved INTEGER NOT NULL DEFAULT 0,
                payload BLOB NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE task_accepted_file (
                task_id TEXT NOT NULL,
                path TEXT NOT NULL,
                blob TEXT NOT NULL,
                by_actor TEXT NOT NULL,
                at REAL NOT NULL,
                command_id TEXT,
                PRIMARY KEY (task_id, path, blob)
            )
            """)
        try db.execute(sql: "CREATE TABLE protection_snapshot (project_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
    }

    /// Journal rows can be discarded. Incidents and accepted files stay in their tables.
    public func discardJournal() throws {
        try database.write { db in try db.execute(sql: "DELETE FROM event") }
    }

    static func recordSafetyEffects(command: DurableTaskCommand, effects: [TaskEffect], task: DurableTask, commandId: CommandID, at: Date, db: Database) throws {
        let rolled: [String]
        if case .resultIncident(_, let names) = command { rolled = names } else { rolled = [] }
        for (index, effect) in effects.enumerated() {
            let id = "\(commandId.uuidString.lowercased())/\(index)"
            switch effect {
            case .reportSuspiciousFiles(let files, let runId):
                _ = try journal(.suspiciousFilesFound(SuspiciousFilesFound(taskId: task.card.id, runId: runId, stageId: task.machine.stageId, files: files)), task: task, commandId: commandId, at: at, db: db)
                try appendFeed(id, taskId: task.card.id, kind: "suspicious_files", text: "Suspicious files: \(files.map(\.path).joined(separator: ", "))", runId: runId, at: at, db: db)
            case .acceptSuspiciousFiles(let files):
                for file in files {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO task_accepted_file(task_id, path, blob, by_actor, at, command_id)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [task.card.id.rawValue, file.path, file.blob, Actor.human.rawValue, at.timeIntervalSince1970, commandId.uuidString])
                }
                var detail = try detail(task.card.id, db: db)
                let known = Set(detail.acceptedFiles.map { FileBlobRef(path: $0.path, blob: $0.blob) })
                for file in files where !known.contains(FileBlobRef(path: file.path, blob: file.blob)) {
                    detail.acceptedFiles.append(AcceptedFile(path: file.path, blob: file.blob, by: .human, at: at, commandId: commandId))
                }
                try saveDetail(detail, taskId: task.card.id, db: db)
                _ = try journal(.suspiciousFilesAccepted(SuspiciousFilesAccepted(taskId: task.card.id, files: files, by: .human, commandId: commandId)), task: task, commandId: commandId, at: at, db: db)
            case .openIncident(let kind, let runId):
                let incident = Incident(id: IncidentID(rawValue: commandId.uuidString.lowercased()), projectId: task.card.projectId, taskId: task.card.id, runId: runId, kind: kind, rolledBack: rolled, openedAt: at)
                try db.execute(sql: "INSERT OR IGNORE INTO incident(id, project_id, task_id, resolved, payload) VALUES (?, ?, ?, 0, ?)", arguments: [incident.id.rawValue, task.card.projectId.rawValue, task.card.id.rawValue, try encode(incident)])
                _ = try journal(.incidentOpened(incident), task: task, commandId: commandId, at: at, db: db)
                try appendFeed(id, taskId: task.card.id, kind: "incident", text: kind.rawValue, runId: runId, at: at, db: db)
                try publishIncidentCount(task.card.projectId, commandId: commandId, at: at, db: db)
            case .resolveIncident:
                let rows = try Row.fetchAll(db, sql: "SELECT id, payload FROM incident WHERE task_id = ? AND resolved = 0", arguments: [task.card.id.rawValue])
                for row in rows {
                    var incident = try decode(Incident.self, row["payload"])
                    incident.resolvedAt = at
                    try db.execute(sql: "UPDATE incident SET resolved = 1, payload = ? WHERE id = ?", arguments: [try encode(incident), incident.id.rawValue])
                    _ = try journal(.incidentResolved(IncidentResolved(incidentId: incident.id, by: .human, commandId: commandId)), task: task, commandId: commandId, at: at, db: db)
                }
                if !rows.isEmpty { try publishIncidentCount(task.card.projectId, commandId: commandId, at: at, db: db) }
            default: break
            }
        }
    }

    static func acceptedFileRows(_ taskId: TaskID, db: Database) throws -> [AcceptedFile] {
        try Row.fetchAll(db, sql: "SELECT path, blob, by_actor, at, command_id FROM task_accepted_file WHERE task_id = ? ORDER BY path, blob", arguments: [taskId.rawValue]).map { row in
            let raw: String? = row["command_id"]
            return AcceptedFile(path: row["path"], blob: row["blob"], by: Actor(rawValue: row["by_actor"]) ?? .human, at: storedDate(row["at"]), commandId: raw.flatMap(UUID.init(uuidString:)))
        }
    }

    static func incidents(projectIds: [ProjectID]?, state: IncidentListState, db: Database) throws -> [Incident] {
        let rows = try Row.fetchAll(db, sql: "SELECT payload, resolved FROM incident ORDER BY id")
        return try rows.compactMap { row -> Incident? in
            let incident = try decode(Incident.self, row["payload"])
            if let projectIds, !projectIds.contains(incident.projectId) { return nil }
            let resolved = (row["resolved"] as Int64) != 0
            if state == .open, resolved { return nil }
            return incident
        }
    }

    static func protectionSnapshot(_ projectId: ProjectID, db: Database) throws -> TaskClone.ProtectionSnapshot? {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM protection_snapshot WHERE project_id = ?", arguments: [projectId.rawValue]) else { return nil }
        return try decode(TaskClone.ProtectionSnapshot.self, data)
    }

    static func saveProtectionSnapshot(_ snapshot: TaskClone.ProtectionSnapshot, projectId: ProjectID, db: Database) throws {
        try db.execute(sql: "INSERT INTO protection_snapshot(project_id, payload) VALUES (?, ?) ON CONFLICT(project_id) DO NOTHING", arguments: [projectId.rawValue, try encode(snapshot)])
    }

    static func replaceProtectionSnapshot(_ snapshot: TaskClone.ProtectionSnapshot, projectId: ProjectID, db: Database) throws {
        try db.execute(sql: "INSERT INTO protection_snapshot(project_id, payload) VALUES (?, ?) ON CONFLICT(project_id) DO UPDATE SET payload = excluded.payload", arguments: [projectId.rawValue, try encode(snapshot)])
    }

    private static func publishIncidentCount(_ projectId: ProjectID, commandId: CommandID, at: Date, db: Database) throws {
        var record = try project(projectId, db: db)
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM incident WHERE project_id = ? AND resolved = 0", arguments: [projectId.rawValue]) ?? 0
        guard record.summary.openIncidentCount != count else { return }
        record.summary.openIncidentCount = count
        _ = try saveUpdatedProject(record, commandId: commandId, at: at, db: db)
    }

    private static func appendFeed(_ id: String, taskId: TaskID, kind: String, text: String, runId: RunID?, at: Date, db: Database) throws {
        var detail = try detail(taskId, db: db)
        guard !detail.feed.contains(where: { $0.id == id }) else { return }
        detail.feed.append(FeedItem(id: id, at: at, kind: kind, text: text, runId: runId))
        try saveDetail(detail, taskId: taskId, db: db)
    }

    private static func storedDate(_ value: DatabaseValue) -> Date {
        if let number = Double.fromDatabaseValue(value) { return Date(timeIntervalSince1970: number) }
        if let number = Int64.fromDatabaseValue(value) { return Date(timeIntervalSince1970: Double(number)) }
        return Date(timeIntervalSince1970: 0)
    }
}
