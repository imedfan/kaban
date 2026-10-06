import Foundation
import GRDB
import KabanProtocol

/// Facts supplied by runtime producers, never fabricated by the scheduler. This is an internal
/// daemon API, not a wire command: environment/catalog/quota producers are separate increments.
public struct SchedulerInputs: Codable, Hashable, Sendable {
    public var flags: [SchedulerFlag]
    public var modelFlags: [ModelFlag]
    public var modelPoolRules: [ModelPoolRule]
    public var quota: QuotaState?
    public var usagePerRun: [ModelPool: Double]

    public init(flags: [SchedulerFlag] = [], modelFlags: [ModelFlag] = [],
                modelPoolRules: [ModelPoolRule] = ModelPoolRule.builtin,
                quota: QuotaState? = nil, usagePerRun: [ModelPool: Double] = [:]) {
        self.flags = flags; self.modelFlags = modelFlags; self.modelPoolRules = modelPoolRules
        self.quota = quota; self.usagePerRun = usagePerRun
    }
}

extension KabanStore {
    static func migrateScheduler(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE scheduler_inputs (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL)")
        try db.execute(sql: "INSERT INTO scheduler_inputs(id, payload) VALUES (1, ?)", arguments: [try encode(SchedulerInputs())])
    }
    static func schedulerInputs(_ db: Database) throws -> SchedulerInputs {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM scheduler_inputs WHERE id = 1") else { throw StoreError.incompleteProjection }
        return try decode(SchedulerInputs.self, data)
    }
    public func setSchedulerInputs(_ inputs: SchedulerInputs, commandId: CommandID, at: Date) throws -> ConfigurationReceipt {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let request = try Self.encode(inputs)
        return try database.write { db in
            if let receipt = try Self.configurationReplay(commandId, request: request, db: db) { return receipt }
            guard Set(inputs.modelFlags.map(\.modelId)).count == inputs.modelFlags.count,
                  inputs.usagePerRun.values.allSatisfy({ $0.isFinite && (0...100).contains($0) }),
                  [inputs.quota?.cm, inputs.quota?.om].compactMap({ $0 }).allSatisfy({ $0.isFinite && (0...100).contains($0) }),
                  inputs.flags.allSatisfy({ flag in
                      switch flag { case .macPaused, .projectPaused, .intakePaused: false; default: true }
                  }) else { throw StoreError.settingsInvalid }
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [request])
            let seq = try Self.journal(.settingsChanged(.init(key: "scheduler", value: "updated", schedulerFlags: Self.schedulerFlags(db))),
                                       projectId: nil, commandId: commandId, at: at, db: db)
            return try Self.configurationReceipt(commandId, request: request, seq: seq, db: db)
        }
    }
    static func expireSchedulerFlags(at: Date, commandId: CommandID, db: Database) throws {
        var inputs = try schedulerInputs(db)
        let previous = inputs.flags
        inputs.flags.removeAll { flag in
            switch flag {
            case .rateLimited(let until, _): until <= at
            case .usageExhaustedUnknown(let reset), .poolUsageExhausted(_, let reset): reset.map { $0 <= at } ?? false
            default: false
            }
        }
        if inputs.flags != previous {
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try encode(inputs)])
            _ = try journal(.settingsChanged(.init(key: "scheduler", value: "updated", schedulerFlags: schedulerFlags(db))),
                            projectId: nil, commandId: commandId, at: at, db: db)
        }
    }
}
