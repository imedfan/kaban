import Foundation
import GRDB
import KabanKit
import KabanProtocol

/// One command, projection, journal, receipt and pending effects commit together.
/// DatabaseQueue serializes concurrent callers; snapshot reads use the same connection transaction.
public final class KabanStore: Sendable {
    private let database: DatabaseQueue

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
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
        try migrator.migrate(database)
    }

    private struct Request: Codable { let kind: String; let taskId: TaskID; let body: Data }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ value: Data) throws -> T { try JSONDecoder().decode(type, from: value) }
    private static func task(_ id: TaskID, db: Database) throws -> DurableTask {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM task WHERE id = ?", arguments: [id.rawValue]) else { throw StoreError.taskMissing }
        return try decode(DurableTask.self, data)
    }
    private static func seq(_ db: Database) throws -> Seq { try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM event") ?? 0 }
    private static func replay(_ id: CommandID, request: Data, db: Database) throws -> DurableReceipt? {
        guard let row = try Row.fetchOne(db, sql: "SELECT request, receipt FROM command WHERE id = ?", arguments: [id.uuidString]) else { return nil }
        guard (row["request"] as Data) == request else { throw StoreError.commandIdConflict }
        return try decode(DurableReceipt.self, row["receipt"])
    }
    private static func journal(_ event: JournalEvent, task: DurableTask, commandId: CommandID, at: Date, db: Database) throws -> Seq {
        // Insert the final envelope after SQLite assigns its durable monotonic sequence.
        try db.execute(sql: "INSERT INTO event(payload) VALUES (?)", arguments: [Data()])
        let seq = db.lastInsertedRowID
        let envelope = EventEnvelope(seq: seq, at: at, projectId: task.card.projectId, commandId: commandId, event: event)
        try db.execute(sql: "UPDATE event SET payload = ? WHERE seq = ?", arguments: [try encode(envelope), seq])
        return seq
    }
    private static func saveReceipt(_ receipt: DurableReceipt, request: Data, db: Database) throws {
        try db.execute(sql: "INSERT INTO command(id, request, receipt) VALUES (?, ?, ?)", arguments: [receipt.commandId.uuidString, request, try encode(receipt)])
    }

    public func createTask(card: TaskCard, pipeline: PipelineConfig, commandId: CommandID, at: Date) throws -> DurableReceipt {
        let request = try Self.encode(Request(kind: "create", taskId: card.id, body: Self.encode(Creation(card: card, pipeline: pipeline))))
        return try database.write { db in
            if let receipt = try Self.replay(commandId, request: request, db: db) { return receipt }
            guard PipelineValidator.validate(config: pipeline).isValid, let machine = TaskMachineState.new(taskId: card.id, pipeline: pipeline) else { throw StoreError.invalidPipeline }
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM task WHERE id = ?)", arguments: [card.id.rawValue]) == true { throw StoreError.taskExists }
            var card = card; machine.apply(to: &card, stage: pipeline.stage(machine.stageId)); card.updatedAt = at
            let task = DurableTask(card: card, machine: machine, pipeline: pipeline)
            try db.execute(sql: "INSERT INTO task(id, payload) VALUES (?, ?)", arguments: [card.id.rawValue, try Self.encode(task)])
            let seq = try Self.journal(.taskCreated(card), task: task, commandId: commandId, at: at, db: db)
            let receipt = DurableReceipt(commandId: commandId, firstSeq: seq, lastSeq: seq, task: task)
            try Self.saveReceipt(receipt, request: request, db: db)
            return receipt
        }
    }
    private struct Creation: Codable { let card: TaskCard; let pipeline: PipelineConfig }

    public func apply(_ command: DurableTaskCommand, taskId: TaskID, commandId: CommandID, at: Date) throws -> DurableReceipt {
        let request = try Self.encode(Request(kind: "transition", taskId: taskId, body: Self.encode(command)))
        return try database.write { db in
            try Self.apply(command, taskId: taskId, commandId: commandId, at: at, request: request, db: db)
        }
    }
    private static func apply(_ command: DurableTaskCommand, taskId: TaskID, commandId: CommandID, at: Date, request: Data, db: Database) throws -> DurableReceipt {
        if let receipt = try Self.replay(commandId, request: request, db: db) { return receipt }
        var task = try Self.task(taskId, db: db)
        let before = task.machine
        let result = TaskMachine.transition(before, command.event, pipeline: task.pipeline)
        if case .rejected(let error) = result.outcome { throw StoreError.rejected(error) }
        var first: Seq?
        if case .applied = result.outcome {
            task.machine = result.state
            task.machine.apply(to: &task.card, stage: task.pipeline.stage(task.machine.stageId)); task.card.updatedAt = at
            try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try Self.encode(task), taskId.rawValue])
            for effect in result.effects {
                if case .recordTransition(let transition) = effect {
                    let seq = try Self.journal(.taskTransitioned(transition), task: task, commandId: commandId, at: at, db: db)
                    if first == nil { first = seq }
                }
            }
            let seq = try Self.journal(.taskUpdated(task.card), task: task, commandId: commandId, at: at, db: db)
            if first == nil { first = seq }
        }
        let receipt = DurableReceipt(commandId: commandId, firstSeq: first, lastSeq: try Self.seq(db), task: task)
        try Self.saveReceipt(receipt, request: request, db: db)
        let pending = result.effects.filter { if case .recordTransition = $0 { return false }; return true }
        if !pending.isEmpty {
            let batch = PendingEffectBatch(version: 1, commandId: commandId, taskId: taskId, effects: pending)
            try db.execute(sql: "INSERT INTO effect_outbox(id, task_id, payload) VALUES (?, ?, ?)", arguments: [commandId.uuidString, taskId.rawValue, try Self.encode(batch)])
        }
        return receipt
    }

    /// Recovery pass and all its transitions commit atomically, including pass replay receipts.
    public func recover(passId: UUID, at: Date) throws -> [DurableReceipt] {
        try database.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM recovery WHERE id = ?", arguments: [passId.uuidString]) {
                return try Self.decode([DurableReceipt].self, data)
            }
            let tasks = try Data.fetchAll(db, sql: "SELECT payload FROM task ORDER BY id").map { try Self.decode(DurableTask.self, $0) }
            var receipts: [DurableReceipt] = []
            for task in tasks where task.machine.state.status == .running || task.machine.state.status == .gating {
                // Recovery replaces the obsolete pre-crash invocation with reducer recovery effects.
                try db.execute(sql: "DELETE FROM effect_outbox WHERE task_id = ?", arguments: [task.card.id.rawValue])
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
        try database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM effect_outbox ORDER BY rowid").map { try Self.decode(PendingEffectBatch.self, $0) } }
    }
    public func acknowledgeEffects(commandId: CommandID) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM effect_outbox WHERE id = ?", arguments: [commandId.uuidString]) }
    }
}
