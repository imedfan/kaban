import Foundation
import GRDB
import KabanKit
import KabanProtocol

/// Loopback endpoint of the host's board server. The port is chosen when the host starts and lives until the daemon exits.
/// `/mcp` and `/git/check` share it (arch. §9, §11).
public struct MCPHostEndpoint: Equatable, Sendable {
    public var port: UInt16
    public var workspaceRoot: String
    public var gitShimExecutable: String
    public init(port: UInt16, workspaceRoot: String, gitShimExecutable: String = KabanGitShim.bundledExecutable.path) {
        self.port = port
        self.workspaceRoot = workspaceRoot
        self.gitShimExecutable = gitShimExecutable
    }
    public var boardURL: String { "http://127.0.0.1:\(port)/mcp" }
    public var gitCheckURL: String { "http://127.0.0.1:\(port)/git/check" }
}

final class MCPHostState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MCPHostEndpoint?
    var endpoint: MCPHostEndpoint? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ endpoint: MCPHostEndpoint?) {
        lock.lock(); value = endpoint; lock.unlock()
    }
}

extension KabanStore {
    /// The host calls this after the board server listens and before the scheduler starts.
    /// Without an endpoint (tests, diagnostic passes) runs get no MCP URLs and no preflight.
    public func attachMCPHost(_ endpoint: MCPHostEndpoint?) {
        mcpHost.set(endpoint)
    }

    public var mcpEndpoint: MCPHostEndpoint? { mcpHost.endpoint }

    /// Before the process starts: install the run config in the clone, run `cursor-agent mcp list` with the run's
    /// working directory and environment, record the result for the project. Any failure to build or read is a block (§9 fail closed).
    func preflightRun(taskId: TaskID, workingDirectory: String, environment: [String: String], at: Date) throws -> MCPPreflightBlock? {
        guard let endpoint = mcpHost.endpoint else { return nil }
        let context = try database.read { db -> (DurableTask, ProjectRecord, Set<String>) in
            let task = try Self.task(taskId, db: db)
            return (task, try Self.project(task.card.projectId, db: db), try Self.mcpAllowlist(task.card.projectId, db: db))
        }
        let stageServers = context.0.pipeline.stage(context.0.machine.stageId)?.agent?.mcp ?? [AgentConfig.boardMcpServer]
        let executable = try currentCursorEnvironment().configuration.executablePath
        var decision: MCPPreflightDecision
        do {
            let planned = MCPPreflight.plan(stageServers: stageServers, allowlist: context.2,
                                            definitions: try readMCPDefinitions(projectPath: context.1.summary.path), boardURL: endpoint.boardURL)
            try installMCPConfig(taskId: taskId, cloneRoot: URL(fileURLWithPath: workingDirectory), generated: planned.configJSON)
            if planned.block == nil {
                let listed = CursorRunner.listMCP(executable: executable, environment: environment, workingDirectory: workingDirectory)
                decision = MCPPreflight.check(planned, listOutput: listed.text, listExit: listed.code ?? -1)
            } else { decision = planned }
        } catch {
            decision = MCPPreflightDecision(names: [], configJSON: "{}", warnings: [], block: .unresolvable("mcp config"))
        }
        try database.write { db in
            try Self.recordMCPPreflight(decision, projectId: context.0.card.projectId, commandId: UUID(), at: at, db: db)
        }
        if decision.block != nil { _ = try restoreInstalledMCPConfigs(taskId: taskId) }
        return decision.block
    }

    /// `recheck(project)`: a fresh `mcp list` in a scratch directory of the workspace with the config of all agent stages.
    /// Nil keeps the stored result: there is no host endpoint, no runnable CLI, or the project folder is gone.
    func recheckMCPDecision(_ projectId: ProjectID, pipeline: PipelineConfig? = nil) throws -> MCPPreflightDecision? {
        guard let endpoint = mcpHost.endpoint else { return nil }
        guard let executable = try currentCursorEnvironment().configuration.executablePath,
              CursorRunner.executableState(executable) == .runnable else { return nil }
        let context = try database.read { db in (try Self.project(projectId, db: db), try Self.mcpAllowlist(projectId, db: db)) }
        let stageServers = [AgentConfig.boardMcpServer] + (pipeline ?? context.0.pipeline).stages.compactMap(\.agent).flatMap(\.mcp)
        let definitions: [MCPServerDefinition]
        do { definitions = try readMCPDefinitions(projectPath: context.0.summary.path) }
        catch { return MCPPreflightDecision(names: [], configJSON: "{}", warnings: [], block: .unresolvable("mcp config")) }
        let planned = MCPPreflight.plan(stageServers: stageServers, allowlist: context.1, definitions: definitions, boardURL: endpoint.boardURL)
        if planned.block != nil { return planned }
        let directory = URL(fileURLWithPath: endpoint.workspaceRoot).appendingPathComponent("mcp-preflight", isDirectory: true)
            .appendingPathComponent(Self.directoryName(projectId), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = try MCPConfigFile.install(cloneRoot: directory, generated: planned.configJSON)
        } catch {
            return MCPPreflightDecision(names: planned.names, configJSON: planned.configJSON, warnings: planned.warnings, block: .unresolvable("mcp config"))
        }
        var environment = try isolatedMCPEnvironment(cursorProcessEnvironment(), endpoint: endpoint, key: "recheck-" + UUID().uuidString)
        environment["KABAN_MCP_URL"] = endpoint.boardURL
        environment["KABAN_GIT_CHECK_URL"] = endpoint.gitCheckURL
        defer { if let home = environment["HOME"] { try? FileManager.default.removeItem(atPath: home) } }
        let listed = CursorRunner.listMCP(executable: executable, environment: environment, workingDirectory: directory.path)
        return MCPPreflight.check(planned, listOutput: listed.text, listExit: listed.code ?? -1)
    }

    func isolatedMCPEnvironment(_ inherited: [String: String], endpoint: MCPHostEndpoint, key: String) throws -> [String: String] {
        var environment = inherited
        // Hash identifiers before using them in paths; run IDs are external protocol values.
        let home = URL(fileURLWithPath: endpoint.workspaceRoot).appendingPathComponent("mcp-homes/" + SHA256Digest.hex(key))
        try CursorRunHome.prepare(home, userHome: URL(fileURLWithPath: inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path))
        environment["HOME"] = home.path
        environment["CURSOR_CONFIG_DIR"] = nil
        environment["CFFIXED_USER_HOME"] = home.path
        environment["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache").path
        environment["XDG_DATA_HOME"] = home.appendingPathComponent(".local/share").path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        return environment
    }

    static func storeMCPPreflight(_ decision: MCPPreflightDecision, projectId: ProjectID, db: Database) throws {
        let detail: String
        let kind: String
        switch decision.block {
        case .unexpected(let name): detail = name; kind = "unexpected"
        case .unresolvable(let name): detail = name; kind = "unresolvable"
        case nil: detail = ""; kind = "unresolvable"
        }
        try db.execute(sql: """
        INSERT INTO mcp_preflight(project_id, blocked, detail, warnings, config_json, kind) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(project_id) DO UPDATE SET blocked = excluded.blocked, detail = excluded.detail, warnings = excluded.warnings, config_json = excluded.config_json, kind = excluded.kind
        """, arguments: [projectId.rawValue, decision.block == nil ? 0 : 1, detail, decision.warnings.joined(separator: "\n"), decision.configJSON, kind])
    }

    /// Stores the result, moves the production project in or out of `mcp_unexpected`, and journals changed flags.
    static func recordMCPPreflight(_ decision: MCPPreflightDecision, projectId: ProjectID, commandId: CommandID, at: Date, db: Database) throws {
        let flags = try schedulerFlags(db)
        try storeMCPPreflight(decision, projectId: projectId, db: db)
        var record = try project(projectId, db: db)
        if decision.block != nil {
            if record.production != nil { record.production?.unavailableReason = .mcpUnexpected }
        } else if record.production?.unavailableReason == .mcpUnexpected {
            record.production?.unavailableReason = nil
        }
        _ = try saveUpdatedProject(record, commandId: commandId, at: at, db: db)
        try recordChangedSchedulerFlags(from: flags, commandId: commandId, at: at, db: db)
    }

    private static func directoryName(_ id: ProjectID) -> String {
        let text = String(id.rawValue.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return text.isEmpty ? "project" : text
    }
}
