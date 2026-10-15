import Foundation
import GRDB
import KabanKit
import KabanProtocol
#if canImport(UserNotifications)
import UserNotifications
#endif

extension KabanStore {
    static func migrateCursorEnvironment(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE cursor_environment (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)")
    }

    static func cursorEnvironment(_ db: Database) throws -> ResolvedCursorEnvironment? {
        try Data.fetchOne(db, sql: "SELECT payload FROM cursor_environment WHERE id = 1")
            .map { try decode(ResolvedCursorEnvironment.self, $0) }
    }

    static func saveCursorEnvironment(_ value: ResolvedCursorEnvironment, db: Database) throws {
        try db.execute(sql: "INSERT INTO cursor_environment(id, payload) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                       arguments: [try encode(value)])
    }

    func currentCursorEnvironment() throws -> ResolvedCursorEnvironment {
        try database.read { db in
            if let value = try Self.cursorEnvironment(db) { return value }
            return .init(configuration: .init(executablePath: try Self.runnerState(db).executable),
                         searchPath: cursorEnvironmentProbe.environment["PATH"] ?? "/usr/bin:/bin", toolchains: [:])
        }
    }

    public func cursorProcessEnvironment() throws -> [String: String] {
        try currentCursorEnvironment().processEnvironment(inheriting: cursorEnvironmentProbe.environment)
    }

    /// Called before admission by both installed and developer hosts. Existing configuration survives restart.
    public func initializeCursorEnvironment(at: Date) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        if try database.read({ try Self.cursorEnvironment($0) }) == nil {
            let configuration = CursorEnvironment(executablePath: try runnerCheck().executable)
            let reply = try execute(.init(command: .configureCursor(environment: configuration)), now: { at })
            if case .error(let error) = reply.result { throw StoreError.rejected(error) }
        } else {
            try refreshRunnerIfDue(at: at, force: true)
            try refreshCatalogIfDue(at: at, force: true)
        }
    }

    func executeCursorEnvironment(_ envelope: CommandEnvelope, now: () -> Date) throws -> CommandReply {
        guard envelope.protocolVersion == KabanCoding.protocolVersion else {
            return .init(commandId: envelope.commandId, seq: nil,
                         result: .error(.init(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
        }
        let request = try Self.encode(envelope)
        do {
            if let reply = try database.read({ try Self.wireReplay(envelope.commandId, request: request, db: $0) }) { return reply }
        } catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
        switch envelope.command {
        case .getCursorEnvironment:
            return .init(commandId: envelope.commandId, seq: nil, result: .cursorEnvironment(try currentCursorEnvironment().configuration))
        case .checkEnvironment:
            let configured = try currentCursorEnvironment()
            let resolved = configured.configuration.executablePath == nil ? cursorEnvironmentProbe.resolve(configured.configuration) : configured
            let report = CursorRunner.environmentReport(executable: resolved.configuration.executablePath,
                environment: resolved.processEnvironment(inheriting: cursorEnvironmentProbe.environment),
                notificationsAuthorized: Self.notificationsAuthorized())
            return .init(commandId: envelope.commandId, seq: nil, result: .environment(report))
        case .configureCursor(let configuration):
            let invalid = configuration.executablePath.map { !CursorEnvironmentProbe.validPath($0) } ?? false
            let at = now()
            let resolved = invalid ? nil : cursorEnvironmentProbe.resolve(configuration)
            let assessment = resolved.map { CursorRunner.assess(executable: $0.configuration.executablePath,
                environment: $0.processEnvironment(inheriting: cursorEnvironmentProbe.environment)) }
            let models = assessment?.catalog
            return try database.write { db in
                if let reply = try Self.wireReplay(envelope.commandId, request: request, db: db) { return reply }
                let reply: CommandReply
                if let resolved, let assessment {
                    try Self.saveCursorEnvironment(resolved, db: db)
                    _ = try Self.saveRunnerAssessment(assessment, executable: resolved.configuration.executablePath,
                        commandId: envelope.commandId, at: at, journalAlways: false, db: db)
                    if let models {
                        try Self.mergeCatalog(models, at: at, db: db)
                        _ = try Self.journal(.settingsChanged(try Self.modelSettingsChange(key: "model_catalog", value: "refreshed", db: db)),
                                             projectId: nil, commandId: envelope.commandId, at: at, db: db)
                    } else {
                        var catalog = try Self.catalogRecord(db)
                        catalog.nextRefreshAt = nil
                        try Self.saveCatalog(catalog, db)
                    }
                    let seq = try Self.journal(.cursorEnvironmentChanged(resolved.configuration), projectId: nil,
                                               commandId: envelope.commandId, at: at, db: db)
                    reply = .init(commandId: envelope.commandId, seq: seq, result: .ok)
                } else {
                    reply = .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "cursor_environment_invalid",
                        message: "Укажите абсолютный путь к Cursor CLI без переводов строк.")))
                }
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)",
                               arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
                return reply
            }
        default: preconditionFailure("Not a Cursor environment command")
        }
    }

    private static func notificationsAuthorized() -> Bool {
        #if canImport(UserNotifications)
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return false }
        let result = NotificationAuthorizationResult()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            result.finish(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
        }
        return result.wait()
        #else
        return false
        #endif
    }
}

#if canImport(UserNotifications)
private final class NotificationAuthorizationResult: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Bool?
    func finish(_ value: Bool) {
        condition.lock(); defer { condition.unlock() }
        result = value; condition.signal()
    }
    func wait() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while result == nil, condition.wait(until: deadline) {}
        return result ?? false
    }
}
#endif
