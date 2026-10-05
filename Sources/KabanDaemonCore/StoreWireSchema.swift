import Foundation
import GRDB
import KabanProtocol

extension KabanStore {
    static func migrateWire(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE wire_command (id TEXT PRIMARY KEY NOT NULL, request BLOB NOT NULL, reply BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE scheduler_pause (scope TEXT PRIMARY KEY NOT NULL)")
    }

    static func rejectWireIdentity(_ id: CommandID, db: Database) throws {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM wire_command WHERE id = ? UNION ALL SELECT 1 FROM project_operation WHERE id = ? UNION ALL SELECT 1 FROM pipeline_operation WHERE id = ?)", arguments: [id.uuidString, id.uuidString, id.uuidString]) == true {
            throw StoreError.commandIdConflict
        }
    }

    static func wireReplay(_ id: CommandID, request: Data, db: Database) throws -> CommandReply? {
        if let row = try Row.fetchOne(db, sql: "SELECT request, reply FROM wire_command WHERE id = ?", arguments: [id.uuidString]) {
            guard (row["request"] as Data) == request else { throw StoreError.commandIdConflict }
            return try decode(CommandReply.self, row["reply"])
        }
        let reserved = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM command WHERE id = ? UNION ALL SELECT 1 FROM configuration_command WHERE id = ?)", arguments: [id.uuidString, id.uuidString])
        if reserved == true { throw StoreError.commandIdConflict }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM project_operation WHERE id = ? UNION ALL SELECT 1 FROM pipeline_operation WHERE id = ?)", arguments: [id.uuidString, id.uuidString]) == true { throw StoreError.commandIdConflict }
        return nil
    }

    static func validateSettings(_ settings: GlobalSettings) throws {
        let options = settings.quotaOptions
        guard settings.maxConcurrentRuns > 0, options.pollInterval > 0,
              options.thresholdCm.isFinite, options.thresholdOm.isFinite,
              (0...100).contains(options.thresholdCm), (0...100).contains(options.thresholdOm),
              !options.enabled || options.consent else { throw StoreError.settingsInvalid }
    }
}
