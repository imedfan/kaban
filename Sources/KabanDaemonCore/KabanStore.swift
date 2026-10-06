import Foundation
import GRDB
import KabanKit
import KabanProtocol

/// One command, projection, journal, receipt and pending effects commit together.
/// DatabaseQueue serializes concurrent callers; snapshot reads use the same connection transaction.
public final class KabanStore: Sendable {
    let database: DatabaseQueue
    let projectOperations = NSRecursiveLock()

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        database = try DatabaseQueue(path: path, configuration: configuration)
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("m1_headless_v1") { db in
            try db.execute(sql: "CREATE TABLE task (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE event (seq INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE command (id TEXT PRIMARY KEY NOT NULL, request BLOB NOT NULL, receipt BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE recovery (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE effect_outbox (id TEXT PRIMARY KEY NOT NULL REFERENCES command(id), task_id TEXT NOT NULL REFERENCES task(id), payload BLOB NOT NULL)")
        }
        migrator.registerMigration("m1_engine_v2", migrate: Self.migrateEngine)
        migrator.registerMigration("m1_wire_v3", migrate: Self.migrateWire)
        migrator.registerMigration("production_projects_v4", migrate: Self.migrateProjects)
        migrator.registerMigration("production_pipelines_v5", migrate: Self.migratePipelines)
        migrator.registerMigration("production_scheduler_v6", migrate: Self.migrateScheduler)
        migrator.registerMigration("effect_execution_v7", migrate: Self.migrateEffectExecution)
        migrator.registerMigration("task_clone_v8", migrate: Self.migrateTaskClones)
        migrator.registerMigration("agent_process_v9", migrate: Self.migrateAgentProcesses)
        migrator.registerMigration("cursor_runner_v10", migrate: Self.migrateCursorRunner)
        try migrator.migrate(database)
    }

    struct Request: Codable { let kind: String; let taskId: TaskID; let body: Data }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: Data) throws -> T { try JSONDecoder().decode(type, from: value) }
    static func task(_ id: TaskID, db: Database) throws -> DurableTask {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM task WHERE id = ?", arguments: [id.rawValue]) else { throw StoreError.taskMissing }
        return try decode(DurableTask.self, data)
    }
    static func seq(_ db: Database) throws -> Seq {
        // AUTOINCREMENT survives retention, even when the entire journal is deleted.
        try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'event'") ?? 0
    }
    static func replay(_ id: CommandID, request: Data, db: Database) throws -> DurableReceipt? {
        try rejectWireIdentity(id, db: db)
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM configuration_command WHERE id = ?)", arguments: [id.uuidString]) == true { throw StoreError.commandIdConflict }
        guard let row = try Row.fetchOne(db, sql: "SELECT request, receipt FROM command WHERE id = ?", arguments: [id.uuidString]) else { return nil }
        guard (row["request"] as Data) == request else { throw StoreError.commandIdConflict }
        return try decode(DurableReceipt.self, row["receipt"])
    }
    static func journal(_ event: JournalEvent, task: DurableTask, commandId: CommandID, at: Date, db: Database) throws -> Seq {
        // Insert the final envelope after SQLite assigns its durable monotonic sequence.
        try db.execute(sql: "INSERT INTO event(payload) VALUES (?)", arguments: [Data()])
        let seq = db.lastInsertedRowID
        let envelope = EventEnvelope(seq: seq, at: at, projectId: task.card.projectId, commandId: commandId, event: event)
        try db.execute(sql: "UPDATE event SET payload = ? WHERE seq = ?", arguments: [try encode(envelope), seq])
        return seq
    }
    static func saveReceipt(_ receipt: DurableReceipt, request: Data, db: Database) throws {
        try db.execute(sql: "INSERT INTO command(id, request, receipt) VALUES (?, ?, ?)", arguments: [receipt.commandId.uuidString, request, try encode(receipt)])
    }

    public func createTask(card: TaskCard, pipeline: PipelineConfig, commandId: CommandID, at: Date) throws -> DurableReceipt {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let request = try Self.encode(Request(kind: "create", taskId: card.id, body: Self.encode(Creation(card: card, pipeline: pipeline))))
        return try database.write { db in
            try Self.createTask(card: card, pipeline: pipeline, commandId: commandId, at: at, request: request, managed: false, body: nil, db: db)
        }
    }
    static func createTask(card: TaskCard, pipeline: PipelineConfig, commandId: CommandID, at: Date, request: Data, managed: Bool, body: String?, db: Database) throws -> DurableReceipt {
        if let receipt = try Self.replay(commandId, request: request, db: db) { return receipt }
        let owner = try Data.fetchOne(db, sql: "SELECT payload FROM project WHERE id = ?", arguments: [card.projectId.rawValue]).map { try Self.decode(ProjectRecord.self, $0) }
        let productionBacklog = owner?.production != nil
        if productionBacklog {
            guard managed, owner?.pipeline == pipeline else { throw StoreError.invalidPipeline }
            try requireNoProjectIntent(card.projectId, db: db)
        }
        guard (productionBacklog ? pipeline.entryStage?.kind == .queue : (managed ? Self.isBoundedPipeline(pipeline) : PipelineValidator.validate(config: pipeline).isValid)), let machine = TaskMachineState.new(taskId: card.id, pipeline: pipeline) else { throw StoreError.invalidPipeline }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM task WHERE id = ?)", arguments: [card.id.rawValue]) == true { throw StoreError.taskExists }
        var card = card; machine.apply(to: &card, stage: pipeline.stage(machine.stageId)); card.updatedAt = at
        let task = DurableTask(card: card, machine: machine, pipeline: pipeline, pipelineVersion: owner?.projectedPipeline.versionHash)
        try db.execute(sql: "INSERT INTO task(id, payload) VALUES (?, ?)", arguments: [card.id.rawValue, try Self.encode(task)])
        try Self.createDetail(task, at: at, db: db)
        let seq = try Self.journal(.taskCreated(card), task: task, commandId: commandId, at: at, db: db)
        if managed {
            var detail = try Self.detail(card.id, db: db); detail.body = body
            try Self.saveDetail(detail, taskId: card.id, db: db)
            try db.execute(sql: "INSERT INTO task_admission(task_id, project_id, created_seq, queue_seq) VALUES (?, ?, ?, ?)", arguments: [card.id.rawValue, card.projectId.rawValue, seq, seq])
        }
        let receipt = DurableReceipt(commandId: commandId, firstSeq: seq, lastSeq: seq, task: task)
        try Self.saveReceipt(receipt, request: request, db: db)
        return receipt
    }
    private struct Creation: Codable { let card: TaskCard; let pipeline: PipelineConfig }

    public func apply(_ command: DurableTaskCommand, taskId: TaskID, commandId: CommandID, at: Date) throws -> DurableReceipt {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let request = try Self.encode(Request(kind: "transition", taskId: taskId, body: Self.encode(command)))
        return try database.write { db in
            try Self.apply(command, taskId: taskId, commandId: commandId, at: at, request: request, db: db)
        }
    }
    static func apply(_ command: DurableTaskCommand, taskId: TaskID, commandId: CommandID, at: Date, request: Data, db: Database) throws -> DurableReceipt {
        if let receipt = try Self.replay(commandId, request: request, db: db) { return receipt }
        let previousLoad = try Self.stageLoads(db)
        let previousFlags = try Self.schedulerFlags(db)
        var task = try Self.task(taskId, db: db)
        let previousRunSpecId = task.runSpecId
        if case .start = command { try Self.bindPipelineForStart(&task, db: db) }
        let before = task.machine
        var reductionPipeline = task.pipeline
        let owner = try Data.fetchOne(db, sql: "SELECT payload FROM project WHERE id = ?", arguments: [task.card.projectId.rawValue]).map { try Self.decode(ProjectRecord.self, $0) }
        // Removing an empty downstream column must not orphan the completing old invocation.
        // Its gates/policy/skill stay frozen; only the exit route falls back to the current graph.
        if command == .resultClean, owner?.production != nil, owner?.production?.unavailableReason == nil,
           let index = reductionPipeline.index(of: before.stageId), let destination = reductionPipeline.stages[index].onSuccess,
           owner?.pipeline.stage(destination) == nil {
            reductionPipeline.stages[index].onSuccess = owner?.pipeline.stage(before.stageId)?.onSuccess
            for stage in owner?.pipeline.stages ?? [] where reductionPipeline.stage(stage.id) == nil { reductionPipeline.stages.append(stage) }
        }
        let result = TaskMachine.transition(before, command.event, pipeline: reductionPipeline)
        if case .rejected(let error) = result.outcome { throw StoreError.rejected(error) }
        try Self.validateManagedCommand(command, task: task, at: at, db: db)
        if case .applied = result.outcome, result.state.stageId != before.stageId {
            if owner?.production != nil {
                let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pipeline_operation WHERE project_id = ?)", arguments: [task.card.projectId.rawValue]) == true
                if pending || owner?.production?.unavailableReason != nil || owner?.projectedPipeline.isValid == false {
                    // Only a completed invocation waits for reload. A human decision must
                    // fail visibly rather than acknowledge an action that cannot be resumed.
                    guard before.state.status == .gating else { throw StoreError.invalidPipeline }
                    return try Self.deferPipelineTransition(command, task: task, commandId: commandId, at: at, request: request, db: db)
                }
            }
        }
        var first: Seq?
        if case .applied = result.outcome {
            let invocationEnded = result.state.stageId != before.stageId || result.state.currentRunId != before.currentRunId
            let stopped = [.cancelled, .done, .paused].contains(result.state.state.status)
            if invocationEnded || stopped || command == .daemonRestarted {
                // A stage exit or interrupted invocation must never deliver its old launch/gate result.
                try Self.supersedeEffects(taskId: taskId, db: db)
                try db.execute(sql: "DELETE FROM pipeline_deferred WHERE task_id = ?", arguments: [taskId.rawValue])
            }
            task.machine = result.state
            if result.state.stageId != before.stageId { task.pipeline = reductionPipeline }
            if result.state.stageId != before.stageId || stopped { task.runSpecId = nil }
            if case .start(let runId) = command, result.effects.contains(where: { effect in
                switch effect { case .startAgentRun, .runGates, .startMerge: true; default: false }
            }) {
                try Self.freezeRunSpec(runId, task: task, db: db)
                task.runSpecId = runId
            }
            task.machine.apply(to: &task.card, stage: task.pipeline.stage(task.machine.stageId)); task.card.updatedAt = at
            if task.machine.state.status != .retryWait { task.card.retryAt = nil }
            for effect in result.effects {
                if case .scheduleRetry(let seconds, _) = effect { task.card.retryAt = at.addingTimeInterval(TimeInterval(seconds)) }
            }
            try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try Self.encode(task), taskId.rawValue])
            for effect in result.effects {
                if case .recordTransition(let transition) = effect {
                    let seq = try Self.journal(.taskTransitioned(transition), task: task, commandId: commandId, at: at, db: db)
                    if first == nil { first = seq }
                }
            }
            let detailSeq = try Self.persistDetail(before: before, task: task, command: command, effects: result.effects, commandId: commandId, at: at, db: db)
            if first == nil { first = detailSeq }
            let seq = try Self.journal(.taskUpdated(task.card), task: task, commandId: commandId, at: at, db: db)
            if first == nil { first = seq }
        }
        try Self.recordChangedLoads(from: previousLoad, commandId: commandId, at: at, db: db)
        try Self.recordChangedSchedulerFlags(from: previousFlags, commandId: commandId, at: at, db: db)
        let receipt = DurableReceipt(commandId: commandId, firstSeq: first, lastSeq: try Self.seq(db), task: task)
        try Self.saveReceipt(receipt, request: request, db: db)
        let pending = result.effects.filter { effect in
            switch effect { case .recordTransition, .recordHumanRequest, .recordHumanAnswer: false; default: true }
        }
        if !pending.isEmpty {
            let batch = PendingEffectBatch(version: 1, commandId: commandId, taskId: taskId, effects: pending, runSpecId: task.runSpecId ?? previousRunSpecId)
            try Self.enqueue(batch, db: db)
            try db.execute(sql: "INSERT INTO effect_outbox(id, task_id, payload) VALUES (?, ?, ?)", arguments: [commandId.uuidString, taskId.rawValue, try Self.encode(batch)])
        }
        return receipt
    }

    /// Recovery pass and all its transitions commit atomically, including pass replay receipts.
    public func recover(passId: UUID, at: Date) throws -> [DurableReceipt] {
        projectOperations.lock(); defer { projectOperations.unlock() }
        return try database.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM recovery WHERE id = ?", arguments: [passId.uuidString]) {
                return try Self.decode([DurableReceipt].self, data)
            }
            let tasks = try Data.fetchAll(db, sql: "SELECT payload FROM task ORDER BY id").map { try Self.decode(DurableTask.self, $0) }
            var receipts: [DurableReceipt] = []
            for task in tasks where task.machine.state.status == .running || task.machine.state.status == .gating {
                if task.machine.state.status == .gating,
                   try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pipeline_deferred WHERE task_id = ? AND stage_id = ? AND run_spec_id IS ?)", arguments: [task.card.id.rawValue, task.machine.stageId.rawValue, task.runSpecId?.rawValue]) == true {
                    // This invocation already finished its gates/result check. Only its stage
                    // exit awaits valid main; restarting it would discard a completed result.
                    try Self.supersedeEffects(taskId: task.card.id, db: db)
                    continue
                }
                // Recovery replaces the obsolete pre-crash invocation with reducer recovery effects.
                try Self.supersedeEffects(taskId: task.card.id, db: db)
                let command = DurableTaskCommand.daemonRestarted
                let request = try Self.encode(Request(kind: "transition", taskId: task.card.id, body: Self.encode(command)))
                receipts.append(try Self.apply(command, taskId: task.card.id, commandId: UUID(), at: at, request: request, db: db))
            }
            try db.execute(sql: "INSERT INTO recovery(id, payload) VALUES (?, ?)", arguments: [passId.uuidString, try Self.encode(receipts)])
            return receipts
        }
    }

    public func snapshot() throws -> DurableSnapshot {
        try database.read { db in
            DurableSnapshot(seq: try Self.seq(db), tasks: try Data.fetchAll(db, sql: "SELECT payload FROM task ORDER BY id").map { try Self.decode(DurableTask.self, $0) })
        }
    }
    public func events(after seq: Seq = 0) throws -> [EventEnvelope] {
        try database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM event WHERE seq > ? ORDER BY seq", arguments: [seq]).map { try Self.decode(EventEnvelope.self, $0) } }
    }
    public func pendingEffects() throws -> [PendingEffectBatch] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM effect_outbox ORDER BY rowid").compactMap { data in
                let batch = try Self.decode(PendingEffectBatch.self, data)
                let pending = try batch.effects.enumerated().filter { index, _ in
                    try String.fetchOne(db, sql: "SELECT status FROM effect WHERE id = ?", arguments: ["\(batch.commandId.uuidString.lowercased())/\(index)"]) == "pending"
                }.map(\.element)
                return pending.isEmpty ? nil : PendingEffectBatch(version: batch.version, commandId: batch.commandId, taskId: batch.taskId, effects: pending, runSpecId: batch.runSpecId)
            }
        }
    }
    public func acknowledgeEffects(commandId: CommandID) throws {
        try database.write { db in
            if let id = try String.fetchOne(db, sql: "SELECT task_id FROM effect_outbox WHERE id = ?", arguments: [commandId.uuidString]), try Self.isManaged(TaskID(rawValue: id), db: db) { throw StoreError.unsupportedEffect }
            try db.execute(sql: "UPDATE effect SET status = 'acknowledged' WHERE command_id = ? AND status = 'pending'", arguments: [commandId.uuidString.lowercased()])
            try db.execute(sql: "DELETE FROM effect_outbox WHERE id = ?", arguments: [commandId.uuidString])
        }
    }
}
