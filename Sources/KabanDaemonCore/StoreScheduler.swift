import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    /// One deterministic admission/start per tick. The token alone is the tick identity:
    /// repeating it returns the original result even when the clock/candidates have advanced.
    public func tick(tickId: UUID, runId: RunID, at: Date) throws -> TickReceipt {
        try database.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT receipt FROM tick WHERE id = ?", arguments: [tickId.uuidString]) {
                return try Self.decode(TickReceipt.self, data)
            }
            _ = try Self.settings(db) // Never start from guessed global settings.
            let projects = try Self.projects(db)
            let tasks = try Self.allTasks(db)
            var cursor = try Self.decode(SchedulerCursor.self, Data.fetchOne(db, sql: "SELECT payload FROM scheduler_cursor WHERE id = 1")!)
            let ordered = Self.projectOrder(projects, cursor: cursor)
            var transitions: [DurableReceipt] = []
            for project in ordered {
                let candidates = try tasks.filter { try $0.card.projectId == project.summary.id && Self.isManaged($0.card.id, db: db) }
                    .sorted { a, b in
                        func rank(_ task: DurableTask) -> Int {
                            let order = task.pipeline.stage(task.machine.stageId)?.priority ?? StageConfig.defaultPriority
                            let rule: PriorityRule = task.machine.priority == .returned ? .returned : task.machine.priority == .answered ? .answered : .fifo
                            return order.firstIndex(of: rule) ?? order.count
                        }
                        let ar = rank(a), br = rank(b)
                        if ar != br { return ar < br }
                        if a.card.priority != b.card.priority { return a.card.priority > b.card.priority }
                        let aq = try Int64.fetchOne(db, sql: "SELECT queue_seq FROM task_admission WHERE task_id = ?", arguments: [a.card.id.rawValue]) ?? 0
                        let bq = try Int64.fetchOne(db, sql: "SELECT queue_seq FROM task_admission WHERE task_id = ?", arguments: [b.card.id.rawValue]) ?? 0
                        return aq == bq ? a.card.id.rawValue < b.card.id.rawValue : aq < bq
                    }
                guard let candidate = try candidates.first(where: { try Self.canStart($0, at: at, db: db) }) else { continue }
                let command = DurableTaskCommand.start(runId)
                let request = try Self.encode(Request(kind: "transition", taskId: candidate.card.id, body: Self.encode(command)))
                transitions.append(try Self.apply(command, taskId: candidate.card.id, commandId: tickId, at: at, request: request, db: db))
                if cursor.project == project.summary.id && cursor.remaining > 0 { cursor.remaining -= 1 }
                else { cursor = SchedulerCursor(project: project.summary.id, remaining: project.summary.weight - 1) }
                try db.execute(sql: "UPDATE scheduler_cursor SET payload = ? WHERE id = 1", arguments: [try Self.encode(cursor)])
                break
            }
            let receipt = TickReceipt(tickId: tickId, transitions: transitions, seq: try Self.seq(db))
            try db.execute(sql: "INSERT INTO tick(id, receipt) VALUES (?, ?)", arguments: [tickId.uuidString, try Self.encode(receipt)])
            return receipt
        }
    }
    private static func projectOrder(_ projects: [ProjectRecord], cursor: SchedulerCursor) -> [ProjectRecord] {
        guard let id = cursor.project, let index = projects.firstIndex(where: { $0.summary.id == id }) else { return projects }
        let first = cursor.remaining > 0 ? index : (index + 1) % max(projects.count, 1)
        return Array(projects[first...]) + Array(projects[..<first])
    }
    static func canStart(_ task: DurableTask, at: Date, db: Database) throws -> Bool {
        let state = task.machine.state
        guard state.status == .queued || state.status == .retryWait, let stage = task.pipeline.stage(task.machine.stageId) else { return false }
        if let retryAt = task.card.retryAt, retryAt > at { return false }
        let project = try Self.project(task.card.projectId, db: db)
        guard project.production == nil, project.summary.availability == .available else { return false }
        let settings = try Self.settings(db)
        guard try !Self.isManuallyPaused(project.summary.id, db: db) else { return false }
        let tasks = try allTasks(db)
        let projectTasks = tasks.filter { $0.card.projectId == task.card.projectId }
        switch stage.kind {
        case .queue:
            guard task.card.hasAcceptanceCriteria else { return false }
            return projectTasks.filter { $0.pipeline.stage($0.machine.stageId)?.kind == .agent && $0.machine.state.status == .waitingHuman }.count < task.pipeline.board.maxWaitingHuman
        case .human:
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM human_admission WHERE task_id = ? AND stage_id = ?)", arguments: [task.card.id.rawValue, stage.id.rawValue]) == true { return true }
            if let limit = stage.effectiveWIP {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM human_admission h JOIN task_admission t ON h.task_id = t.task_id WHERE t.project_id = ? AND h.stage_id = ?", arguments: [task.card.projectId.rawValue, stage.id.rawValue])! < limit
            }
            return true // Human admissions use no live agent slot.
        case .agent:
            let running = tasks.filter { $0.machine.state.status == .running }.count
            guard running < settings.maxConcurrentRuns else { return false }
            if let max = project.summary.maxRuns, projectTasks.filter({ $0.machine.state.status == .running }).count >= max { return false }
            // A retry already owns a reservation. Count other tasks, so it can resume even after limit shrink.
            if !state.status.occupiesWIP, let limit = stage.effectiveWIP {
                let used = projectTasks.filter { $0.card.id != task.card.id && $0.machine.stageId == stage.id && $0.machine.state.status.occupiesWIP }.count
                if used >= limit { return false }
            }
            return true
        default: return false
        }
    }
}
