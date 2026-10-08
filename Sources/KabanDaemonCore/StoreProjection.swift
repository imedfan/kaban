import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    private struct Registration: Codable { let summary: ProjectSummary; let pipeline: PipelineConfig }
    private struct ManagedCreation: Codable { let card: TaskCard; let body: String; let pipeline: PipelineConfig }

    /// Fixed fake-pipeline registration only; no repository inspection or pipeline replacement.
    public func registerProject(_ summary: ProjectSummary, pipeline: PipelineConfig, commandId: CommandID, at: Date) throws -> ConfigurationReceipt {
        let request = try Self.encode(Registration(summary: summary, pipeline: pipeline))
        return try database.write { db in
            if let receipt = try Self.configurationReplay(commandId, request: request, db: db) { return receipt }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM removed_project WHERE project_id = ?)", arguments: [summary.id.rawValue]) != true else { throw StoreError.projectMissing }
            guard Self.isBoundedPipeline(pipeline), summary.weight > 0, summary.maxRuns.map({ $0 > 0 }) ?? true else { throw StoreError.invalidPipeline }
            let existing = try Data.fetchOne(db, sql: "SELECT payload FROM project WHERE id = ?", arguments: [summary.id.rawValue]).map { try Self.decode(ProjectRecord.self, $0) }
            if let existing, existing.production != nil || existing.pipeline != pipeline { throw StoreError.invalidPipeline }
            let projected = try Self.mcpProjectSummary(summary, db: db)
            let record = ProjectRecord(summary: projected, pipeline: pipeline, version: existing?.version ?? commandId.uuidString.lowercased())
            try db.execute(sql: "INSERT INTO project(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [summary.id.rawValue, try Self.encode(record)])
            _ = try Self.journal(existing == nil ? .projectAdded(projected) : .projectUpdated(projected), projectId: summary.id, commandId: commandId, at: at, db: db)
            let context = try Self.pipelineContext(summary.id, db: db)
            let seq = try Self.journal(.pipelineApplied(pipeline.summary(projectId: summary.id, versionHash: record.version,
                issues: PipelineValidator.validate(config: pipeline, context: context).issues, mcpAllowlist: context.mcpAllowlist)), projectId: summary.id, commandId: commandId, at: at, db: db)
            return try Self.configurationReceipt(commandId, request: request, seq: seq, db: db)
        }
    }
    static func isBoundedPipeline(_ p: PipelineConfig) -> Bool {
        guard PipelineValidator.validate(config: p).errors.allSatisfy({ $0.code == "merge_count" }), p.stages.count == 4,
              p.stages.map(\.kind) == [.queue, .agent, .human, .terminal],
              p.successChain(from: p.entryStage?.id) == p.stages.map(\.id) else { return false }
        return p.stages.allSatisfy { $0.gates.isEmpty && $0.hooks.onEnter == nil && $0.hooks.onExit == nil }
    }
    public func setSettings(_ settings: GlobalSettings, commandId: CommandID, at: Date) throws -> ConfigurationReceipt {
        let request = try Self.encode(settings)
        return try database.write { db in
            if let receipt = try Self.configurationReplay(commandId, request: request, db: db) { return receipt }
            try Self.validateSettings(settings)
            try db.execute(sql: "INSERT INTO global_settings(id, payload) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [request])
            let event = SettingsChange(key: "global", value: "updated", settings: settings)
            let seq = try Self.journal(.settingsChanged(event), projectId: nil, commandId: commandId, at: at, db: db)
            return try Self.configurationReceipt(commandId, request: request, seq: seq, db: db)
        }
    }
    public func createTask(card: TaskCard, body: String, commandId: CommandID, at: Date) throws -> DurableReceipt {
        projectOperations.lock(); defer { projectOperations.unlock() }
        return try database.write { db in
            let project = try Self.project(card.projectId, db: db)
            let request = try Self.encode(Request(kind: "managed_create", taskId: card.id, body: Self.encode(ManagedCreation(card: card, body: body, pipeline: project.pipeline))))
            return try Self.createTask(card: card, pipeline: project.pipeline, commandId: commandId, at: at, request: request, managed: true, body: body, db: db)
        }
    }
    public func getTaskDetail(_ taskId: TaskID) throws -> TaskDetail {
        try database.read { db in try Self.taskDetail(taskId, db: db) }
    }
    static func taskDetail(_ taskId: TaskID, db: Database) throws -> TaskDetail {
        let task = try Self.task(taskId, db: db); let d = try Self.detail(taskId, db: db)
        let detail = TaskDetail(seq: try Self.seq(db), task: try Self.projectedCard(task, db: db), feed: d.feed, runs: d.runs, humanRequests: d.questions.map(\.request),
                                suspiciousFiles: task.machine.suspiciousFiles, acceptedFiles: try Self.acceptedFileRows(taskId, db: db), clonePath: d.clonePath,
                                artifacts: d.artifacts, gitGrants: d.gitGrants, gitDenials: d.gitDenials, body: d.body, wipRestoreOperations: try Self.wipRestoreOperations(taskId, db: db), modelStages: try Self.taskModelStages(task, db: db),
                                fileCheck: .init(maxFileBytes: task.pipeline.suspiciousFiles.maxFileBytes,
                                                 includesUncommitted: task.pipeline.git.preset == .strict,
                                                 baseCommit: try Self.cloneRecord(taskId, db: db)?.baseCommit,
                                                 bounceLimitTotal: task.pipeline.board.bounceLimitTotal,
                                                 returnPipeline: task.pipeline.summary(projectId: task.card.projectId, versionHash: task.pipelineVersion)))
        try Self.ensureWireFit(detail, code: CommandError.detailTooLargeCode, message: "Детали задачи не помещаются в сообщение. История запусков доступна отдельно.")
        return detail
    }
    static func runSummaries(_ taskId: TaskID, db: Database) throws -> [RunSummary] {
        _ = try task(taskId, db: db)
        return try detail(taskId, db: db).runs
    }
    static func ensureWireFit<T: Encodable>(_ value: T, code: String, message: String) throws {
        let bytes = try KabanCoding.makeEncoder().encode(value).count
        guard bytes <= DaemonWire.maxMessageBytes else {
            throw StoreError.rejected(CommandError(code: code, message: message, params: ["bytes": String(bytes), "limit": String(DaemonWire.maxMessageBytes)]))
        }
    }
    public func getSnapshot() throws -> Snapshot {
        try database.read { db in
            let projects = try Self.projects(db)
            let removed = try Set(String.fetchAll(db, sql: "SELECT project_id FROM removed_project"))
            let tasks = try Self.allTasks(db).filter { !removed.contains($0.card.projectId.rawValue) }
            // A v1 unregistered project lacks an authoritative projection. An open incident is part of that projection.
            guard tasks.allSatisfy({ task in projects.contains { $0.summary.id == task.card.projectId && ($0.production != nil || $0.pipeline == task.pipeline) } }) else { throw StoreError.incompleteProjection }
            let settings = try Data.fetchOne(db, sql: "SELECT payload FROM global_settings WHERE id = 1").map { try Self.decode(GlobalSettings.self, $0) }
            let flags = try Self.schedulerFlags(db)
            let inputs = try Self.schedulerInputs(db)
            let snapshot = Snapshot(seq: try Self.seq(db), projects: try projects.map { try Self.mcpProjectSummary($0.summary, db: db) },
                                    pipelines: try projects.map { try Self.mcpPipelineSummary($0.projectedPipeline, db: db) },
                                    tasks: try tasks.map { try Self.projectedCard($0, db: db) }, schedulerFlags: flags, modelFlags: inputs.modelFlags, quota: inputs.quota,
                                    openIncidentCount: projects.reduce(0) { $0 + $1.summary.openIncidentCount },
                                    stageLoad: try Self.stageLoads(db), settings: settings, modelCatalog: try Self.visibleModelCatalog(db), modelPoolRules: inputs.modelPoolRules)
            try Self.ensureWireFit(snapshot, code: CommandError.snapshotTooLargeCode, message: "Снимок доски не помещается в сообщение.")
            return snapshot
        }
    }
    static func projects(_ db: Database) throws -> [ProjectRecord] {
        try Data.fetchAll(db, sql: "SELECT payload FROM project WHERE id NOT IN (SELECT project_id FROM removed_project) ORDER BY id").map { try decode(ProjectRecord.self, $0) }
    }
    static func projectedCard(_ task: DurableTask, db: Database) throws -> TaskCard {
        var card = task.card
        card.mergeQueueSequence = task.pipeline.stage(task.machine.stageId)?.kind == .merge
            ? try Int64.fetchOne(db, sql: "SELECT queue_seq FROM task_admission WHERE task_id = ?", arguments: [card.id.rawValue]) : nil
        return card
    }
    static func journal(_ event: JournalEvent, projectId: ProjectID?, commandId: CommandID, at: Date, db: Database) throws -> Seq {
        try db.execute(sql: "INSERT INTO event(payload) VALUES (?)", arguments: [Data()])
        let seq = db.lastInsertedRowID
        let envelope = EventEnvelope(seq: seq, at: at, projectId: projectId, commandId: commandId, event: event)
        try db.execute(sql: "UPDATE event SET payload = ? WHERE seq = ?", arguments: [try encode(envelope), seq])
        return seq
    }
    static func configurationReplay(_ id: CommandID, request: Data, db: Database) throws -> ConfigurationReceipt? {
        try rejectWireIdentity(id, db: db)
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM command WHERE id = ?)", arguments: [id.uuidString]) == true { throw StoreError.commandIdConflict }
        guard let row = try Row.fetchOne(db, sql: "SELECT request, receipt FROM configuration_command WHERE id = ?", arguments: [id.uuidString]) else { return nil }
        guard (row["request"] as Data) == request else { throw StoreError.commandIdConflict }
        return try decode(ConfigurationReceipt.self, row["receipt"])
    }
    static func configurationReceipt(_ id: CommandID, request: Data, seq: Seq, db: Database) throws -> ConfigurationReceipt {
        let receipt = ConfigurationReceipt(commandId: id, seq: seq)
        try db.execute(sql: "INSERT INTO configuration_command(id, request, receipt) VALUES (?, ?, ?)", arguments: [id.uuidString, request, try encode(receipt)])
        return receipt
    }
    static func stageLoads(_ db: Database) throws -> [StageLoad] {
        let tasks = try allTasks(db)
        return try projects(db).flatMap { p in try p.pipeline.stages.map { stage in
            let admitted = try Set(String.fetchAll(db, sql: "SELECT task_id FROM human_admission"))
            let used = tasks.filter { task in
                guard task.card.projectId == p.summary.id, task.machine.stageId == stage.id else { return false }
                return stage.kind == .human ? admitted.contains(task.card.id.rawValue) : task.machine.state.status.occupiesWIP
            }.count
            return StageLoad(projectId: p.summary.id, stageId: stage.id, wipUsed: used, wipLimit: stage.effectiveWIP)
        } }
    }
    static func recordChangedLoads(from previous: [StageLoad], commandId: CommandID, at: Date, db: Database) throws {
        for load in try stageLoads(db) where previous.first(where: { $0.projectId == load.projectId && $0.stageId == load.stageId }) != load {
            _ = try journal(.stageLoadChanged(load), projectId: load.projectId, commandId: commandId, at: at, db: db)
        }
    }
}
