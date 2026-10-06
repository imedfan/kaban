import Foundation
import GRDB
import KabanKit
import KabanProtocol

struct ModelCatalogRecord: Codable, Equatable {
    var rows: [ModelInfo] = []
    var nextRefreshAt: Date?
}

extension KabanStore {
    static let modelCatalogRefreshInterval: TimeInterval = 86_400

    static func migrateModelCatalog(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE model_catalog (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)")
        try db.execute(sql: "INSERT INTO model_catalog (id, payload) VALUES (1, ?)", arguments: [try encode(ModelCatalogRecord())])
        try db.execute(sql: "CREATE TABLE model_override (task_id TEXT NOT NULL, stage_id TEXT NOT NULL, model TEXT NOT NULL, PRIMARY KEY (task_id, stage_id))")
    }

    static func catalogRecord(_ db: Database) throws -> ModelCatalogRecord {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM model_catalog WHERE id = 1") else { throw StoreError.incompleteProjection }
        return try decode(ModelCatalogRecord.self, data)
    }

    static func saveCatalog(_ record: ModelCatalogRecord, _ db: Database) throws {
        try db.execute(sql: "UPDATE model_catalog SET payload = ? WHERE id = 1", arguments: [try encode(record)])
        guard db.changesCount == 1 else { throw StoreError.incompleteProjection }
    }

    public func modelCatalog() throws -> [ModelInfo] {
        try database.read { try Self.catalogRecord($0).rows }
    }

    public func resolvedModel(taskId: TaskID, stageId: StageID) throws -> ModelID? {
        try database.read { db in try Self.resolvedModel(taskId: taskId, stageId: stageId, db: db) }
    }

    static func resolvedModel(taskId: TaskID, stageId: StageID, db: Database) throws -> ModelID? {
        if let model = try String.fetchOne(db, sql: "SELECT model FROM model_override WHERE task_id = ? AND stage_id = ?", arguments: [taskId.rawValue, stageId.rawValue]) {
            return ModelID(rawValue: model)
        }
        return try task(taskId, db: db).pipeline.stage(stageId)?.agent?.model
    }

    static func modelOverrides(_ db: Database) throws -> [String: ModelID] {
        Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT task_id, stage_id, model FROM model_override").map { row in
            ("\(row["task_id"] as String)\n\(row["stage_id"] as String)", ModelID(rawValue: row["model"] as String))
        })
    }

    /// Unrecognized text leaves the stored catalog unchanged.
    @discardableResult
    public func replaceCatalog(text: String, at: Date) throws -> Bool {
        guard let parsed = ModelCatalogMatcher.parseListModels(text) else { return false }
        projectOperations.lock(); defer { projectOperations.unlock() }
        try database.write { db in try Self.mergeCatalog(parsed, at: at, db: db) }
        return true
    }

    static func mergeCatalog(_ parsed: [ModelInfo], at: Date, db: Database) throws {
        var record = try catalogRecord(db)
        let inputs = try schedulerInputs(db)
        let previous = Dictionary(uniqueKeysWithValues: record.rows.map { ($0.id, $0) })
        var rows: [ModelInfo] = []
        for item in parsed {
            var row = item
            row.pool = ModelPoolResolver.pool(for: row.id, rules: inputs.modelPoolRules)
            if let old = previous[row.id] {
                row.needsReview = old.needsReview
                row.missingSince = nil
            }
            if !row.forbidden, inputs.modelPoolRules.contains(where: { $0.source == .user && ModelPoolResolver.matches($0.pattern, row.id.rawValue) }) {
                row.needsReview = false
            }
            rows.append(row)
        }
        let seen = Set(rows.map(\.id))
        for old in record.rows where !seen.contains(old.id) && !old.forbidden {
            var missing = old
            if missing.missingSince == nil { missing.missingSince = at }
            rows.append(missing)
            try installUnavailable(modelId: old.id, requested: old.name, at: at, db: db)
        }
        for row in rows where row.missingSince == nil && !row.forbidden {
            var inputs = try schedulerInputs(db)
            if let index = inputs.modelFlags.firstIndex(where: { $0.modelId == row.id && $0.reason == .unavailable }) {
                inputs.modelFlags.remove(at: index)
                try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
            }
        }
        record.rows = rows
        record.nextRefreshAt = at.addingTimeInterval(modelCatalogRefreshInterval)
        try saveCatalog(record, db)
    }

    func refreshCatalogIfDue(at: Date) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let due = try database.read { db -> Bool in
            let record = try Self.catalogRecord(db)
            let executable = try Self.runnerState(db).executable
            guard let executable, !executable.isEmpty else { return false }
            return record.nextRefreshAt.map { $0 <= at } ?? true
        }
        guard due else { return }
        let executable = try database.read { try Self.runnerState($0).executable }
        let text = CursorRunner.listModelsText(executable: executable, environment: ProcessInfo.processInfo.environment) ?? ""
        guard let parsed = ModelCatalogMatcher.parseListModels(text) else {
            try database.write { db in
                var record = try Self.catalogRecord(db)
                record.nextRefreshAt = at.addingTimeInterval(Self.modelCatalogRefreshInterval)
                try Self.saveCatalog(record, db)
            }
            return
        }
        try database.write { db in try Self.mergeCatalog(parsed, at: at, db: db) }
    }

    public func observeModelInit(taskId: TaskID, runId: RunID, actualName: String?, fallback: String?, commandId: CommandID, at: Date) throws -> ModelObservation {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let task = try database.read { try Self.task(taskId, db: $0) }
        let stageId = task.machine.stageId
        let stageModel = task.pipeline.stage(stageId)?.agent?.model
        let requested = try database.read { try Self.resolvedModel(taskId: taskId, stageId: stageId, db: $0) }
        let rows = try database.read { try Self.catalogRecord($0).rows }
        guard let requested else { return .unconfirmed }
        let observation = ModelCatalogMatcher.observe(requestedId: requested, actualName: actualName, rows: rows)
        switch observation {
        case .confirmed:
            return .confirmed
        case .unconfirmed:
            let request = try Self.encode(Request(kind: "model-unconfirmed", taskId: taskId, body: Data((actualName ?? "").utf8)))
            try database.write { db in
                if try Self.replay(commandId, request: request, db: db) != nil { return }
                var detail = try Self.detail(taskId, db: db)
                let shown = actualName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                detail.feed.append(FeedItem(id: commandId.uuidString.lowercased() + "/model", at: at, kind: "model_unconfirmed", text: shown.isEmpty ? "Фактическое имя модели не подтверждено." : "Фактическое имя «\(shown)» не подтверждено каталогом.", runId: runId))
                try Self.saveDetail(detail, taskId: taskId, db: db)
                let current = try Self.task(taskId, db: db)
                let seq = try Self.seq(db)
                try Self.saveReceipt(DurableReceipt(commandId: commandId, firstSeq: seq, lastSeq: seq, task: current), request: request, db: db)
            }
            return .unconfirmed
        case .substituted(let requestedName, let actual):
            _ = try apply(.modelMismatch(runId: runId, requested: requestedName, actual: actual, fallback: fallback), taskId: taskId, commandId: commandId, at: at)
            if let stageModel, requested != stageModel {
                try database.write { db in try Self.retargetModelFlag(from: stageModel, to: requested, db: db) }
            }
            return observation
        }
    }

    static func retargetModelFlag(from source: ModelID, to target: ModelID, db: Database) throws {
        var inputs = try schedulerInputs(db)
        guard let index = inputs.modelFlags.firstIndex(where: { $0.modelId == source && $0.reason == .substituted }) else { return }
        var flag = inputs.modelFlags.remove(at: index)
        flag.modelId = target
        inputs.modelFlags.removeAll { $0.modelId == target }
        inputs.modelFlags.append(flag)
        try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
    }

    static func installUnavailable(modelId: ModelID, requested: String, at: Date, db: Database) throws {
        var inputs = try schedulerInputs(db)
        inputs.modelFlags.removeAll { $0.modelId == modelId && $0.reason == .unavailable }
        guard !inputs.modelFlags.contains(where: { $0.modelId == modelId }) else {
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
            return
        }
        inputs.modelFlags.append(ModelFlag(modelId: modelId, reason: .unavailable, requested: requested, since: at))
        try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
    }

    static func installModelFlag(_ request: ModelFlagRequest, at: Date, commandId: CommandID, db: Database) throws {
        _ = commandId
        var inputs = try schedulerInputs(db)
        inputs.modelFlags.removeAll { $0.modelId == request.modelId }
        inputs.modelFlags.append(ModelFlag(modelId: request.modelId, reason: request.reason, requested: request.requested ?? request.modelId.rawValue, actual: request.reason == .substituted ? request.actual : nil, fallbackModel: request.fallbackModel, since: at))
        try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
    }

    func setModelOverride(_ envelope: CommandEnvelope, taskId: TaskID, stageId: StageID, model: ModelID?, at: Date) throws -> CommandReply {
        try commitModelCommand(envelope, at: at) { db in
            let task = try Self.task(taskId, db: db)
            guard task.pipeline.stage(stageId) != nil else { throw StoreError.rejected(CommandError(code: CommandError.notFoundCode, message: "Стадия не найдена.")) }
            if let model {
                let trimmed = model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased() == "auto" {
                    throw StoreError.rejected(CommandError(code: ValidationCode.modelAutoForbidden, message: "Нужна явная модель; auto запрещён."))
                }
                guard PipelineValidator.hasExplicitModel(ModelID(rawValue: trimmed)) else {
                    throw StoreError.rejected(CommandError(code: ValidationCode.modelMissing, message: "Нужна явная модель."))
                }
                try db.execute(sql: "INSERT INTO model_override(task_id, stage_id, model) VALUES (?, ?, ?) ON CONFLICT(task_id, stage_id) DO UPDATE SET model = excluded.model", arguments: [taskId.rawValue, stageId.rawValue, trimmed])
            } else {
                try db.execute(sql: "DELETE FROM model_override WHERE task_id = ? AND stage_id = ?", arguments: [taskId.rawValue, stageId.rawValue])
            }
            return try Self.journal(.taskUpdated(task.card), task: task, commandId: envelope.commandId, at: at, db: db)
        }
    }

    func setModelPoolRule(_ envelope: CommandEnvelope, pattern: String, pool: ModelPool, at: Date) throws -> CommandReply {
        try commitModelCommand(envelope, at: at) { db in
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.contains("\n"), trimmed.lowercased() != "auto" else {
                throw StoreError.rejected(CommandError(code: "invalid_request", message: "Укажите шаблон модели, отличный от auto."))
            }
            var inputs = try Self.schedulerInputs(db)
            inputs.modelPoolRules.removeAll { $0.source == .user && $0.pattern == trimmed }
            inputs.modelPoolRules.append(ModelPoolRule(pattern: trimmed, pool: pool, source: .user))
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try Self.encode(inputs)])
            try Self.recomputeCatalogPools(db: db)
            return try Self.journal(.settingsChanged(.init(key: "model_pool", value: "updated")), projectId: nil, commandId: envelope.commandId, at: at, db: db)
        }
    }

    func removeModelPoolRule(_ envelope: CommandEnvelope, pattern: String, at: Date) throws -> CommandReply {
        try commitModelCommand(envelope, at: at) { db in
            var inputs = try Self.schedulerInputs(db)
            inputs.modelPoolRules.removeAll { $0.source == .user && $0.pattern == pattern }
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try Self.encode(inputs)])
            try Self.recomputeCatalogPools(db: db)
            return try Self.journal(.settingsChanged(.init(key: "model_pool", value: "updated")), projectId: nil, commandId: envelope.commandId, at: at, db: db)
        }
    }

    func clearModelFlag(_ envelope: CommandEnvelope, modelId: ModelID, at: Date) throws -> CommandReply {
        try commitModelCommand(envelope, at: at) { db in
            var inputs = try Self.schedulerInputs(db)
            inputs.modelFlags.removeAll { $0.modelId == modelId }
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try Self.encode(inputs)])
            return try Self.journal(.settingsChanged(.init(key: "model_flag", value: "cleared")), projectId: nil, commandId: envelope.commandId, at: at, db: db)
        }
    }

    private func commitModelCommand(_ envelope: CommandEnvelope, at: Date, body: (Database) throws -> Seq) throws -> CommandReply {
        _ = at
        let request = try Self.encode(envelope)
        if let reply = try database.read({ try Self.wireReplay(envelope.commandId, request: request, db: $0) }) { return reply }
        return try database.write { db in
            if let reply = try Self.wireReplay(envelope.commandId, request: request, db: db) { return reply }
            guard envelope.protocolVersion == KabanCoding.protocolVersion else {
                let reply = CommandReply(commandId: envelope.commandId, seq: nil, result: .error(CommandError(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
                return reply
            }
            let reply: CommandReply
            do {
                var seq: Seq?
                try db.inSavepoint {
                    seq = try body(db)
                    return .commit
                }
                reply = CommandReply(commandId: envelope.commandId, seq: seq, result: .ok)
            } catch let error as StoreError {
                reply = Self.failure(error, commandId: envelope.commandId)
            }
            try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
            return reply
        }
    }

    static func recomputeCatalogPools(db: Database) throws {
        var record = try catalogRecord(db)
        let rules = try schedulerInputs(db).modelPoolRules
        for index in record.rows.indices {
            record.rows[index].pool = ModelPoolResolver.pool(for: record.rows[index].id, rules: rules)
            if !record.rows[index].forbidden, rules.contains(where: { $0.source == .user && ModelPoolResolver.matches($0.pattern, record.rows[index].id.rawValue) }) {
                record.rows[index].needsReview = false
            }
        }
        try saveCatalog(record, db)
    }

    func refreshModelCatalog(_ envelope: CommandEnvelope, at: Date) throws -> CommandReply {
        let request = try Self.encode(envelope)
        if let reply = try database.read({ try Self.wireReplay(envelope.commandId, request: request, db: $0) }) { return reply }
        let executable = try database.read { try Self.runnerState($0).executable }
        let text = CursorRunner.listModelsText(executable: executable, environment: ProcessInfo.processInfo.environment) ?? ""
        return try database.write { db in
            if let reply = try Self.wireReplay(envelope.commandId, request: request, db: db) { return reply }
            guard envelope.protocolVersion == KabanCoding.protocolVersion else {
                let reply = CommandReply(commandId: envelope.commandId, seq: nil, result: .error(CommandError(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
                return reply
            }
            if let parsed = ModelCatalogMatcher.parseListModels(text) {
                try Self.mergeCatalog(parsed, at: at, db: db)
            } else {
                var record = try Self.catalogRecord(db)
                record.nextRefreshAt = at.addingTimeInterval(Self.modelCatalogRefreshInterval)
                try Self.saveCatalog(record, db)
            }
            let seq = try Self.seq(db)
            let reply = CommandReply(commandId: envelope.commandId, seq: seq, result: .ok)
            try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
            return reply
        }
    }
}


