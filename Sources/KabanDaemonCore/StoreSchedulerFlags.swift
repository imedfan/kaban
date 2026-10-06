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
        var flags = try schedulerInputs(db).flags
        if pauses.contains(pauseScope(nil)) { flags.append(.macPaused) }
        let tasks = try allTasks(db)
        for project in try projects(db) {
            let id = project.summary.id
            if project.summary.availability == .missing {
                flags.append(.projectUnavailable(id, .projectMissing, detail: nil))
            } else if let reason = project.production?.unavailableReason {
                flags.append(.projectUnavailable(id, reason, detail: project.projectedPipeline.issues.first(where: { $0.severity == .error })?.message))
            }
            if pauses.contains(pauseScope(id)) { flags.append(.projectPaused(id)) }
            let waiting = tasks.filter { $0.card.projectId == id && $0.machine.state.status == .waitingHuman && $0.machine.state != .waitingHuman(.review) }.count
            if waiting >= project.pipeline.board.maxWaitingHuman { flags.append(.intakePaused(id)) }
            if tasks.contains(where: { $0.card.projectId == id && $0.machine.state == .blocked(.mainDirty) }) { flags.append(.mergeBlocked(id)) }
        }
        var seen: Set<SchedulerFlag> = []
        return flags.filter { seen.insert($0).inserted }
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
