import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    static func migrateMCPIsolation(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE project_mcp_allow (
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            PRIMARY KEY (project_id, name)
        )
        """)
        try db.execute(sql: """
        CREATE TABLE mcp_preflight (
            project_id TEXT PRIMARY KEY NOT NULL,
            blocked INTEGER NOT NULL,
            detail TEXT NOT NULL,
            warnings TEXT NOT NULL,
            config_json TEXT NOT NULL
        )
        """)
        try db.execute(sql: """
        CREATE TABLE mcp_config_swap (
            task_id TEXT PRIMARY KEY NOT NULL,
            clone_path TEXT NOT NULL,
            previous BLOB,
            had_file INTEGER NOT NULL,
            exclude_added INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE TABLE mcp_isolation_line (task_id TEXT PRIMARY KEY NOT NULL, line TEXT NOT NULL)")
    }

    static func mcpBlockDetail(_ projectId: ProjectID, db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT detail FROM mcp_preflight WHERE project_id = ? AND blocked = 1", arguments: [projectId.rawValue])
    }

    /// Records the preflight for the task's current stage. A block rejects the next `start` and does not approve every server.
    public func applyMCPPreflight(taskId: TaskID, definitions: [MCPServerDefinition], boardURL: String, listOutput: String, listExit: Int32, at: Date) throws -> MCPPreflightDecision {
        projectOperations.lock(); defer { projectOperations.unlock() }
        return try database.write { db in
            let task = try Self.task(taskId, db: db)
            let stageServers = task.pipeline.stage(task.machine.stageId)?.agent?.mcp ?? [AgentConfig.boardMcpServer]
            let allow = try Self.mcpAllowlist(task.card.projectId, db: db)
            let decision = MCPPreflight.decide(stageServers: stageServers, allowlist: allow, definitions: definitions, boardURL: boardURL, listOutput: listOutput, listExit: listExit)
            try Self.recordMCPPreflight(decision, projectId: task.card.projectId, commandId: UUID(), at: at, db: db)
            return decision
        }
    }

    public func installMCPConfig(taskId: TaskID, cloneRoot: URL, generated: String) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let installed = try MCPConfigFile.capture(cloneRoot: cloneRoot)
        try database.write { db in
            try db.execute(sql: """
            INSERT INTO mcp_config_swap(task_id, clone_path, previous, had_file, exclude_added) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(task_id) DO NOTHING
            """, arguments: [taskId.rawValue, cloneRoot.path, installed.previous, installed.previous == nil ? 0 : 1, installed.excludeAdded ? 1 : 0])
        }
        _ = try MCPConfigFile.install(cloneRoot: cloneRoot, generated: generated)
    }

    /// Puts back the bytes captured before the swap. `taskId` limits it to one clone (result check, blocked preflight).
    func restoreInstalledMCPConfigs(taskId: TaskID? = nil) throws -> [String] {
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT task_id, clone_path, previous, had_file, exclude_added FROM mcp_config_swap WHERE ? IS NULL OR task_id = ? ORDER BY task_id", arguments: [taskId?.rawValue, taskId?.rawValue])
        }
        var lines: [String] = []
        var restored: [String] = []
        for row in rows {
            let taskId: String = row["task_id"]
            let path: String = row["clone_path"]
            let hadFile: Int64 = row["had_file"]
            let excludeAdded: Int64 = row["exclude_added"]
            let previous: Data? = hadFile == 0 ? nil : row["previous"]
            try MCPConfigFile.restore(cloneRoot: URL(fileURLWithPath: path), installed: MCPInstalledFile(previous: previous, excludeAdded: excludeAdded == 1))
            lines.append("mcp restore \(taskId) clean")
            restored.append(taskId)
        }
        if !restored.isEmpty {
            try database.write { db in
                for taskId in restored {
                    try db.execute(sql: "DELETE FROM mcp_config_swap WHERE task_id = ?", arguments: [taskId])
                }
            }
        }
        return lines
    }

    public func runMCPIsolationPass(at: Date) throws -> [String] {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let stored = try database.read { db in try String.fetchAll(db, sql: "SELECT line FROM mcp_isolation_line ORDER BY task_id") }
        if !stored.isEmpty { return stored }
        let lines = try restoreInstalledMCPConfigs()
        if lines.isEmpty { return [] }
        try database.write { db in
            for line in lines {
                let taskId = line.split(separator: " ").dropFirst(2).first.map(String.init) ?? line
                try db.execute(sql: "INSERT INTO mcp_isolation_line(task_id, line) VALUES (?, ?)", arguments: [taskId, line])
            }
        }
        _ = at
        return lines
    }
}
