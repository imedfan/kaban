import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    /// One admission/start and at most 32 changed blocking labels per transaction.
    /// Replay precedes reconciliation, clock-dependent selection and new command IDs.
    public func tick(tickId: UUID, runId: RunID, at: Date) throws -> TickReceipt {
        try schedulerTick(tickId: tickId, runId: runId, at: at, recordIdle: true)!
    }
    /// Idle wakes do not create receipts. Backoff never holds a transaction/timer open.
    public func runSchedulerPass(at: Date, budget: Int = 8) throws -> [TickReceipt] {
        precondition((1...32).contains(budget))
        try refreshRunnerIfDue(at: at)
        guard try database.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM global_settings)") == true }) else { return [] }
        var receipts: [TickReceipt] = []
        for _ in 0..<budget {
            guard let receipt = try schedulerTick(tickId: UUID(), runId: RunID(rawValue: UUID().uuidString.lowercased()), at: at, recordIdle: false) else { break }
            receipts.append(receipt)
        }
        return receipts
    }
    private func schedulerTick(tickId: UUID, runId: RunID, at: Date, recordIdle: Bool) throws -> TickReceipt? {
        projectOperations.lock(); defer { projectOperations.unlock() }
        return try database.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT receipt FROM tick WHERE id = ?", arguments: [tickId.uuidString]) {
                return try Self.decode(TickReceipt.self, data)
            }
            let beforeSeq = try Self.seq(db)
            _ = try Self.settings(db)
            try Self.expireSchedulerFlags(at: at, commandId: tickId, db: db)
            let context = try SchedulerContext(db)
            var cursor = try Self.decode(SchedulerCursor.self, Data.fetchOne(db, sql: "SELECT payload FROM scheduler_cursor WHERE id = 1")!)
            var transitions: [DurableReceipt] = []
            var labels = 0
            for project in Self.projectOrder(context.projects, cursor: cursor) {
                let distances = project.pipeline.stages.reduce(into: [StageID: Int]()) { result, stage in
                    result[stage.id] = project.pipeline.successChain(from: stage.id).count
                }
                let candidates = context.tasks.filter { $0.card.projectId == project.summary.id && context.managed.contains($0.card.id.rawValue) }
                    .sorted { a, b in
                        let ai = distances[a.machine.stageId] ?? Int.max, bi = distances[b.machine.stageId] ?? Int.max
                        if ai != bi { return ai < bi } // Follow the success graph, not YAML/display order.
                        func rank(_ task: DurableTask) -> Int {
                            let order = project.pipeline.stage(task.machine.stageId)?.priority ?? StageConfig.defaultPriority
                            let rule: PriorityRule = task.machine.priority == .returned ? .returned : task.machine.priority == .answered ? .answered : .fifo
                            return order.firstIndex(of: rule) ?? order.count
                        }
                        let ar = rank(a), br = rank(b)
                        if ar != br { return ar < br }
                        if a.card.priority != b.card.priority { return a.card.priority > b.card.priority }
                        let aq = context.queue[a.card.id.rawValue] ?? 0, bq = context.queue[b.card.id.rawValue] ?? 0
                        return aq == bq ? a.card.id.rawValue < b.card.id.rawValue : aq < bq
                    }
                var selected: DurableTask?
                for candidate in candidates {
                    switch context.eligibility(candidate, at: at) {
                    case .ready: selected = candidate
                    case .blocked(let reason):
                        if labels < 32, candidate.machine.state != .queued(reason) {
                            let id = UUID(), command = DurableTaskCommand.startBlocked(reason)
                            let request = try Self.encode(Request(kind: "transition", taskId: candidate.card.id, body: Self.encode(command)))
                            transitions.append(try Self.apply(command, taskId: candidate.card.id, commandId: id, at: at, request: request, db: db))
                            labels += 1
                        }
                    case .ineligible: break
                    }
                    if selected != nil { break }
                }
                guard let selected else { continue }
                let command = DurableTaskCommand.start(runId)
                let request = try Self.encode(Request(kind: "transition", taskId: selected.card.id, body: Self.encode(command)))
                transitions.append(try Self.apply(command, taskId: selected.card.id, commandId: tickId, at: at, request: request, db: db))
                if cursor.project == project.summary.id && cursor.remaining > 0 { cursor.remaining -= 1 }
                else { cursor = SchedulerCursor(project: project.summary.id, remaining: project.summary.weight - 1) }
                try db.execute(sql: "UPDATE scheduler_cursor SET payload = ? WHERE id = 1", arguments: [try Self.encode(cursor)])
                break
            }
            let receipt = TickReceipt(tickId: tickId, transitions: transitions, seq: try Self.seq(db))
            guard recordIdle || !transitions.isEmpty || receipt.seq != beforeSeq else { return nil }
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
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM global_settings)") == true else { return false }
        if case .ready = try SchedulerContext(db).eligibility(task, at: at) { return true }
        return false
    }
}

private struct SchedulerContext {
    enum Eligibility { case ready, blocked(QueuedReason), ineligible }
    let projects: [ProjectRecord]
    let tasks: [DurableTask]
    let settings: GlobalSettings
    let inputs: SchedulerInputs
    let flags: [SchedulerFlag]
    let managed: Set<String>
    let queue: [String: Int64]
    let admissions: [String: String]
    let pendingProjects: Set<String>
    init(_ db: Database) throws {
        projects = try KabanStore.projects(db); tasks = try KabanStore.allTasks(db)
        settings = try KabanStore.settings(db); inputs = try KabanStore.schedulerInputs(db)
        flags = try KabanStore.schedulerFlags(db)
        let rows = try Row.fetchAll(db, sql: "SELECT task_id, queue_seq FROM task_admission")
        managed = Set(rows.map { $0["task_id"] as String })
        queue = Dictionary(uniqueKeysWithValues: rows.map { ($0["task_id"] as String, $0["queue_seq"] as Int64) })
        admissions = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT task_id, stage_id FROM human_admission").map { ($0["task_id"] as String, $0["stage_id"] as String) })
        pendingProjects = try Set(String.fetchAll(db, sql: "SELECT project_id FROM pipeline_operation UNION SELECT project_id FROM project_operation"))
    }
    func eligibility(_ task: DurableTask, at: Date) -> Eligibility {
        guard task.machine.state.status == .queued || task.machine.state.status == .retryWait,
              task.card.retryAt.map({ $0 <= at }) ?? true,
              let project = projects.first(where: { $0.summary.id == task.card.projectId }),
              project.summary.availability == .available, project.production?.unavailableReason == nil,
              !pendingProjects.contains(project.summary.id.rawValue),
              project.production == nil || project.projectedPipeline.isValid,
              let stage = project.pipeline.stage(task.machine.stageId) else { return .ineligible }
        let projectTasks = tasks.filter { $0.card.projectId == project.summary.id }
        for flag in flags {
            switch flag {
            case .macPaused: return .ineligible
            case .projectPaused(let id), .projectUnavailable(let id, _, _): if id == project.summary.id { return .ineligible }
            case .intakePaused(let id): if id == project.summary.id && stage.kind == .queue { return .ineligible }
            case .mergeBlocked(let id): if id == project.summary.id && stage.kind == .merge { return .ineligible }
            default: break
            }
        }
        let modelStage = stage.kind == .queue ? project.pipeline.firstAgentStage : stage
        if modelStage?.kind == .agent, let model = modelStage?.agent?.model {
            let pool = ModelPoolResolver.pool(for: model, rules: inputs.modelPoolRules)
            for flag in flags {
                switch flag {
                case .rateLimited(let until, _): if until > at { return .ineligible }
                case .usageExhaustedUnknown(let reset): if reset.map({ $0 > at }) ?? true { return .ineligible }
                case .runnerUnavailable: return .ineligible
                case .poolUsageExhausted(let blocked, let reset):
                    if pool == blocked && (reset.map({ $0 > at }) ?? true) { return .blocked(pool == .cm ? .quotaCm : .quotaOm) }
                default: break
                }
            }
            if inputs.modelFlags.contains(where: { $0.modelId == model }) { return .blocked(.modelFlag) }
            if settings.quotaOptions.enabled && settings.quotaOptions.consent,
               let quota = inputs.quota, !quota.isStale(now: at, staleAfter: 60), let used = quota.percentUsed(pool) {
                let live = tasks.filter { task in
                    task.machine.state == .running && task.pipeline.stage(task.machine.stageId)?.agent?.model.map {
                        ModelPoolResolver.pool(for: $0, rules: inputs.modelPoolRules) == pool
                    } == true
                }.count
                let threshold = pool == .cm ? settings.quotaOptions.thresholdCm : settings.quotaOptions.thresholdOm
                if 100 - used - Double(live) * (inputs.usagePerRun[pool] ?? 2) <= threshold {
                    return .blocked(pool == .cm ? .quotaCm : .quotaOm)
                }
            }
        }
        switch stage.kind {
        case .queue: return task.card.hasAcceptanceCriteria ? .ready : .ineligible
        case .human:
            if admissions[task.card.id.rawValue] == stage.id.rawValue { return .ready }
            if let limit = stage.effectiveWIP {
                let used = projectTasks.filter { admissions[$0.card.id.rawValue] == stage.id.rawValue }.count
                if used >= limit { return .ineligible }
            }
        case .agent, .gate, .merge:
            if stage.kind == .agent {
                if tasks.filter({ $0.machine.state == .running }).count >= settings.maxConcurrentRuns { return .ineligible }
                if let max = project.summary.maxRuns, projectTasks.filter({ $0.machine.state == .running }).count >= max { return .ineligible }
            }
            if !task.machine.state.status.occupiesWIP, let limit = stage.effectiveWIP {
                let used = projectTasks.filter { $0.card.id != task.card.id && $0.machine.stageId == stage.id && $0.machine.state.status.occupiesWIP }.count
                if used >= limit { return .ineligible }
            }
        case .terminal: break
        }
        return .ready
    }
}
