import Foundation
import GRDB
import KabanProtocol

extension KabanStore {
    static func pauseScope(_ projectId: ProjectID?) -> String { projectId.map { "project:\($0.rawValue)" } ?? "mac" }

    static func isManuallyPaused(_ projectId: ProjectID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM scheduler_pause WHERE scope IN (?, ?))",
                          arguments: [pauseScope(nil), pauseScope(projectId)]) == true
    }

    static func schedulerFlags(_ db: Database) throws -> [SchedulerFlag] {
        let pauses = try Set(String.fetchAll(db, sql: "SELECT scope FROM scheduler_pause"))
        var flags: [SchedulerFlag] = pauses.contains(pauseScope(nil)) ? [.macPaused] : []
        let tasks = try allTasks(db)
        for project in try projects(db) {
            let id = project.summary.id
            if pauses.contains(pauseScope(id)) { flags.append(.projectPaused(id)) }
            let waiting = tasks.filter { $0.card.projectId == id && $0.pipeline.stage($0.machine.stageId)?.kind == .agent && $0.machine.state.status == .waitingHuman }.count
            if waiting >= project.pipeline.board.maxWaitingHuman { flags.append(.intakePaused(id)) }
        }
        return flags
    }

    static func recordChangedSchedulerFlags(from previous: [SchedulerFlag], commandId: CommandID, at: Date, db: Database) throws {
        let flags = try schedulerFlags(db)
        if flags != previous {
            _ = try journal(.settingsChanged(SettingsChange(key: "scheduler", value: "updated", schedulerFlags: flags)), projectId: nil, commandId: commandId, at: at, db: db)
        }
    }

    static func setManualPause(_ paused: Bool, projectId: ProjectID?, commandId: CommandID, at: Date, db: Database) throws -> Seq {
        if let projectId { _ = try project(projectId, db: db) }
        let scope = pauseScope(projectId)
        if paused { try db.execute(sql: "INSERT INTO scheduler_pause(scope) VALUES (?) ON CONFLICT(scope) DO NOTHING", arguments: [scope]) }
        else { try db.execute(sql: "DELETE FROM scheduler_pause WHERE scope = ?", arguments: [scope]) }
        // Even an unchanged value produces an acknowledgement event for the pending UI operation.
        return try journal(.settingsChanged(SettingsChange(key: "scheduler", value: "updated", schedulerFlags: schedulerFlags(db))), projectId: nil, commandId: commandId, at: at, db: db)
    }
}
