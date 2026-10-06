import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    static func migrateModelProbes(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE model_probe (model TEXT PRIMARY KEY NOT NULL, requested_at REAL NOT NULL, next_at REAL NOT NULL)")
    }

    public struct ModelProbe: Equatable, Sendable {
        public var model: ModelID
        public var requestedAt: Date
        public var nextAt: Date
    }

    public func modelProbes() throws -> [ModelProbe] {
        try database.read { db in try Self.probeRows(db) }
    }

    static func probeRows(_ db: Database) throws -> [ModelProbe] {
        try Row.fetchAll(db, sql: "SELECT model, requested_at, next_at FROM model_probe ORDER BY model").map { row in
            ModelProbe(model: ModelID(rawValue: row["model"] as String),
                       requestedAt: Date(timeIntervalSince1970: row["requested_at"] as Double),
                       nextAt: Date(timeIntervalSince1970: row["next_at"] as Double))
        }
    }

    /// Records the probe time. It does not start `cursor-agent -p`.
    static func installProbe(model: ModelID, at: Date, db: Database) throws {
        let now = at.timeIntervalSince1970
        if let next = try Double.fetchOne(db, sql: "SELECT next_at FROM model_probe WHERE model = ?", arguments: [model.rawValue]), next > now {
            return
        }
        let following = at.addingTimeInterval(CursorLimitClassifier.probeInterval).timeIntervalSince1970
        try db.execute(sql: """
            INSERT INTO model_probe (model, requested_at, next_at) VALUES (?, ?, ?)
            ON CONFLICT(model) DO UPDATE SET requested_at = excluded.requested_at, next_at = excluded.next_at
            """, arguments: [model.rawValue, now, following])
    }

    static func installLimitEffect(_ effect: TaskEffect, at: Date, db: Database) throws {
        switch effect {
        case .raiseRateLimit:
            var inputs = try schedulerInputs(db)
            let active = inputs.flags.compactMap { flag -> Int? in
                if case .rateLimited(let until, let step) = flag, until > at { return step }
                return nil
            }.first
            let cooldown = CursorLimitClassifier.cooldown(after: active)
            inputs.flags.removeAll { if case .rateLimited = $0 { true } else { false } }
            inputs.flags.append(.rateLimited(cooldownUntil: at.addingTimeInterval(cooldown.seconds), step: cooldown.step))
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
        case .raiseUsageExhausted(let pool):
            var inputs = try schedulerInputs(db)
            inputs.flags.removeAll { flag in
                switch (pool, flag) {
                case (nil, .usageExhaustedUnknown): true
                case (let wanted?, .poolUsageExhausted(let existing, _)) where existing == wanted: true
                default: false
                }
            }
            let reset = inputs.quota?.billingCycleEnd ?? at.addingTimeInterval(CursorLimitClassifier.unknownReset)
            if let pool { inputs.flags.append(.poolUsageExhausted(pool, resetsAt: reset)) }
            else { inputs.flags.append(.usageExhaustedUnknown(resetsAt: reset)) }
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
        case .raiseRunnerUnavailable(let reason):
            var inputs = try schedulerInputs(db)
            inputs.flags.removeAll { if case .runnerUnavailable = $0 { true } else { false } }
            inputs.flags.append(.runnerUnavailable(reason))
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
        case .requestModelProbe(let model):
            try installProbe(model: model, at: at, db: db)
        default:
            break
        }
    }

    static func replaceUsageReset(_ date: Date, pool: ModelPool?, db: Database) throws {
        var inputs = try schedulerInputs(db)
        inputs.flags = inputs.flags.map { flag in
            switch (pool, flag) {
            case (nil, .usageExhaustedUnknown): return .usageExhaustedUnknown(resetsAt: date)
            case (let wanted?, .poolUsageExhausted(let existing, _)) where existing == wanted:
                return .poolUsageExhausted(existing, resetsAt: date)
            default: return flag
            }
        }
        try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
    }

    /// Classifies one agent error. A known limit releases only this run. Unknown text is a redacted diagnostic and sets no flag.
    public func observeAgentFailure(taskId: TaskID, runId: RunID, text: String, commandId: CommandID, at: Date) throws -> CursorLimitClass? {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let task = try database.read { try Self.task(taskId, db: $0) }
        guard task.machine.state == .running, task.machine.currentRunId == runId else { return nil }
        let model = try database.read { try Self.resolvedModel(taskId: taskId, stageId: task.machine.stageId, db: $0) }
        let inputs = try database.read { try Self.schedulerInputs($0) }
        let pool = model.map { ModelPoolResolver.pool(for: $0, rules: inputs.modelPoolRules) }
        guard let kind = CursorLimitClassifier.classify(text, pool: pool) else { return nil }
        switch kind {
        case .rateLimit:
            _ = try apply(.runFailed(runId, .rateLimit), taskId: taskId, commandId: commandId, at: at)
        case .usageExhausted(let exhausted):
            _ = try apply(.runFailed(runId, .usageExhausted(exhausted)), taskId: taskId, commandId: commandId, at: at)
            if let date = CursorLimitClassifier.resetDate(in: text) {
                try database.write { try Self.replaceUsageReset(date, pool: exhausted, db: $0) }
            }
        case .modelUnavailable:
            _ = try apply(.runFailed(runId, .modelUnavailable), taskId: taskId, commandId: commandId, at: at)
        case .runnerAuth:
            _ = try apply(.runFailed(runId, .runnerAuth), taskId: taskId, commandId: commandId, at: at)
        case .unknown:
            let request = try Self.encode(Request(kind: "limit-unknown", taskId: taskId, body: Data(CursorLimitClassifier.redact(text).utf8)))
            try database.write { db in
                if try Self.replay(commandId, request: request, db: db) != nil { return }
                var detail = try Self.detail(taskId, db: db)
                detail.feed.append(FeedItem(id: commandId.uuidString.lowercased() + "/limit", at: at, kind: "limit_unclassified", text: CursorLimitClassifier.redact(text), runId: runId))
                try Self.saveDetail(detail, taskId: taskId, db: db)
                let current = try Self.task(taskId, db: db)
                let seq = try Self.seq(db)
                try Self.saveReceipt(DurableReceipt(commandId: commandId, firstSeq: seq, lastSeq: seq, task: current), request: request, db: db)
            }
        }
        return kind
    }

    func resumeAfterRateLimit(_ envelope: CommandEnvelope, at: Date) throws -> CommandReply {
        let request = try Self.encode(envelope)
        if let reply = try database.read({ try Self.wireReplay(envelope.commandId, request: request, db: $0) }) { return reply }
        return try database.write { db in
            if let reply = try Self.wireReplay(envelope.commandId, request: request, db: db) { return reply }
            guard envelope.protocolVersion == KabanCoding.protocolVersion else {
                let reply = CommandReply(commandId: envelope.commandId, seq: nil, result: .error(CommandError(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
                return reply
            }
            var inputs = try Self.schedulerInputs(db)
            inputs.flags.removeAll { if case .rateLimited = $0 { true } else { false } }
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try Self.encode(inputs)])
            let seq = try Self.journal(.settingsChanged(.init(key: "scheduler", value: "updated", schedulerFlags: Self.schedulerFlags(db))), projectId: nil, commandId: envelope.commandId, at: at, db: db)
            let reply = CommandReply(commandId: envelope.commandId, seq: seq, result: .ok)
            try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
            return reply
        }
    }
}
