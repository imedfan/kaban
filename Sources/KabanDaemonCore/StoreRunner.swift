import Foundation
import GRDB
import KabanKit
import KabanProtocol

public struct RunnerCheckState: Codable, Equatable, Sendable {
    public var executable: String?
    public var version: String?
    public var reason: RunnerUnavailableReason?
    public var checkedAt: Date?
    public var nextCheckAt: Date?
    public var limitsNote: String?
    public var authOK: Bool?
    public init() {}
}

extension KabanStore {
    static func migrateCursorRunner(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE runner_check (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)")
        try db.execute(sql: "INSERT INTO runner_check (id, payload) VALUES (1, ?)", arguments: [try encode(RunnerCheckState())])
    }

    static func runnerState(_ db: Database) throws -> RunnerCheckState {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM runner_check WHERE id = 1") else { throw StoreError.incompleteProjection }
        return try decode(RunnerCheckState.self, data)
    }

    static func saveRunner(_ state: RunnerCheckState, _ db: Database) throws {
        try db.execute(sql: "UPDATE runner_check SET payload = ? WHERE id = 1", arguments: [try encode(state)])
        guard db.changesCount == 1 else { throw StoreError.incompleteProjection }
    }

    public func runnerCheck() throws -> RunnerCheckState {
        try database.read { try Self.runnerState($0) }
    }

    /// Records the absolute executable. It does not clear `runner_unavailable` until a real probe says the runner is available.
    public func setRunnerExecutable(_ path: String) throws {
        guard CursorEnvironmentProbe.validPath(path) else { throw StoreError.settingsInvalid }
        projectOperations.lock(); defer { projectOperations.unlock() }
        try database.write { db in
            var state = try Self.runnerState(db)
            state.executable = path
            state.nextCheckAt = nil
            try Self.saveRunner(state, db)
            if var configuration = try Self.cursorEnvironment(db) {
                configuration.configuration.executablePath = path
                try Self.saveCursorEnvironment(configuration, db: db)
            }
        }
    }

    /// An initialized discovery with no executable also raises agent_missing and can discover a later install.
    public func refreshRunnerIfDue(at: Date, force: Bool = false) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let state = try database.read { try Self.runnerState($0) }
        let initialized = try database.read { try Self.cursorEnvironment($0) != nil }
        guard state.executable != nil || initialized else { return }
        if !force, let next = state.nextCheckAt, next > at { return }
        _ = try commitRunnerCheck(commandId: CommandID(), at: at, request: nil, journalAlways: false)
    }

    func recheckRunner(_ envelope: CommandEnvelope, at: Date) throws -> CommandReply {
        let request = try Self.encode(envelope)
        do {
            if let reply = try database.read({ try Self.wireReplay(envelope.commandId, request: request, db: $0) }) { return reply }
        } catch let error as StoreError {
            return Self.failure(error, commandId: envelope.commandId)
        }
        guard envelope.protocolVersion == KabanCoding.protocolVersion else {
            return try database.write { db in
                if let reply = try Self.wireReplay(envelope.commandId, request: request, db: db) { return reply }
                let reply = CommandReply(commandId: envelope.commandId, seq: nil, result: .error(CommandError(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
                return reply
            }
        }
        return try commitRunnerCheck(commandId: envelope.commandId, at: at, request: request, journalAlways: true)
    }

    private func commitRunnerCheck(commandId: CommandID, at: Date, request: Data?, journalAlways: Bool) throws -> CommandReply {
        let current = try currentCursorEnvironment()
        let configured = current.configuration.executablePath == nil ? cursorEnvironmentProbe.resolve(current.configuration) : current
        let assessment = CursorRunner.assess(executable: configured.configuration.executablePath,
            environment: configured.processEnvironment(inheriting: cursorEnvironmentProbe.environment))
        return try database.write { db in
            if let request, let reply = try Self.wireReplay(commandId, request: request, db: db) { return reply }
            let previous = try Self.runnerState(db)
            var seq = try Self.saveRunnerAssessment(assessment, executable: configured.configuration.executablePath,
                commandId: commandId, at: at, journalAlways: journalAlways, db: db)
            if assessment.reason == nil, let catalog = assessment.catalog,
               previous.reason != nil || configured != current {
                try Self.mergeCatalog(catalog, at: at, db: db)
                seq = try Self.journal(.settingsChanged(try Self.modelSettingsChange(key: "model_catalog", value: "refreshed", db: db)),
                                       projectId: nil, commandId: commandId, at: at, db: db)
            }
            if configured != current {
                try Self.saveCursorEnvironment(configured, db: db)
                seq = try Self.journal(.cursorEnvironmentChanged(configured.configuration), projectId: nil,
                                       commandId: commandId, at: at, db: db)
            }
            let reply = CommandReply(commandId: commandId, seq: seq, result: .ok)
            if let request {
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [commandId.uuidString, request, try Self.encode(reply)])
            }
            return reply
        }
    }

    static func saveRunnerAssessment(_ assessment: CursorRunnerAssessment, executable: String?, commandId: CommandID,
                                     at: Date, journalAlways: Bool, db: Database) throws -> Seq {
        var stored = try runnerState(db)
        stored.executable = executable
        stored.version = assessment.version
        stored.reason = assessment.reason
        stored.checkedAt = at
        stored.nextCheckAt = at.addingTimeInterval(CursorRunner.recheckInterval)
        stored.limitsNote = assessment.limitsNote
        stored.authOK = assessment.authOK
        try Self.saveRunner(stored, db)
        var inputs = try Self.schedulerInputs(db)
        if let index = inputs.flags.firstIndex(where: { if case .runnerUnavailable = $0 { true } else { false } }) {
            if let reason = assessment.reason { inputs.flags[index] = .runnerUnavailable(reason) }
            else { inputs.flags.remove(at: index) }
        } else if let reason = assessment.reason {
            inputs.flags.append(.runnerUnavailable(reason))
        }
        let previous = try Self.schedulerFlags(db)
        try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try Self.encode(inputs)])
        let flags = try Self.schedulerFlags(db)
        let seq: Seq
        if journalAlways || flags != previous {
            seq = try Self.journal(.settingsChanged(.init(key: "scheduler", value: "updated", schedulerFlags: flags)), projectId: nil, commandId: commandId, at: at, db: db)
        } else {
            seq = try Self.seq(db)
        }
        return seq
    }
}
