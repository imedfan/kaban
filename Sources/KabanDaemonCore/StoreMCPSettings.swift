import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    static func mcpAllowlist(_ id: ProjectID, db: Database) throws -> Set<String> {
        try Set(String.fetchAll(db, sql: "SELECT name FROM project_mcp_allow WHERE project_id = ?", arguments: [id.rawValue]))
    }
    static func mcpProjectSummary(_ summary: ProjectSummary, db: Database) throws -> ProjectSummary {
        var summary = summary
        summary.mcpAllowlist = [AgentConfig.boardMcpServer] + (try mcpAllowlist(summary.id, db: db)).subtracting([AgentConfig.boardMcpServer]).sorted()
        summary.mcpIssue = nil
        if let row = try Row.fetchOne(db, sql: "SELECT detail, kind FROM mcp_preflight WHERE project_id = ? AND blocked = 1", arguments: [summary.id.rawValue]) {
            summary.mcpIssue = .init(kind: McpPreflightIssue.Kind(rawValue: row["kind"]) ?? .unresolvable, name: row["detail"])
        }
        return summary
    }
    static func mcpPipelineSummary(_ pipeline: PipelineSummary, db: Database) throws -> PipelineSummary {
        var pipeline = pipeline
        let allow = try mcpAllowlist(pipeline.projectId, db: db)
        for index in pipeline.stages.indices {
            if let selected = pipeline.stages[index].mcp {
                pipeline.stages[index].effectiveMcp = MCPPreflight.allowedNames(stageServers: selected, allowlist: allow)
            }
        }
        return pipeline
    }

    func executeMCPCommand(_ envelope: CommandEnvelope, at: Date) throws -> CommandReply {
        let request = try Self.encode(envelope)
        let id: ProjectID, selection: [McpServerRef]?
        switch envelope.command {
        case .listProjectMcpServers(let project): id = project; selection = nil
        case .setProjectMcpAllowlist(let project, let servers): id = project; selection = servers
        default: preconditionFailure("Not an MCP settings command")
        }
        do {
            if selection != nil, let replay = try database.read({ try Self.wireReplay(envelope.commandId, request: request, db: $0) }) { return replay }
            guard envelope.protocolVersion == KabanCoding.protocolVersion else { throw CommandError(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.") }
            let observed = try database.read { try Self.project(id, db: $0) }
            let catalog = try readMCPCatalog(projectPath: observed.summary.path)
            guard let selection else {
                try Self.ensureWireFit(catalog, code: "mcp_catalog_too_large", message: "Список MCP превышает лимит сообщения.")
                return .init(commandId: envelope.commandId, seq: nil, result: .mcpServers(catalog))
            }
            guard selection.count <= 1_024, selection.allSatisfy({ $0.name == AgentConfig.boardMcpServer || catalog.contains($0) }) else {
                throw CommandError(code: "mcp_catalog_changed", message: "Выбранный сервер больше не найден в указанном источнике. Перечитайте список.")
            }
            return try database.write { db in
                let flags = try Self.schedulerFlags(db)
                var record = try Self.project(id, db: db)
                guard record.summary.path == observed.summary.path else { throw CommandError(code: "project_changed", message: "Путь проекта изменился; перечитайте список MCP.") }
                try Self.requireNoProjectIntent(id, db: db)
                try db.execute(sql: "DELETE FROM project_mcp_allow WHERE project_id = ?", arguments: [id.rawValue])
                for name in Set(selection.map(\.name)).sorted() where name != AgentConfig.boardMcpServer {
                    try db.execute(sql: "INSERT INTO project_mcp_allow(project_id, name) VALUES (?, ?)", arguments: [id.rawValue, name])
                }
                if let source = record.production?.source {
                    try Self.applyPipelineSource(source, edits: record.projectedPipeline.hasUncommittedEdits, record: &record, db: db)
                }
                _ = try Self.saveUpdatedProject(record, commandId: envelope.commandId, at: at, db: db)
                _ = try Self.journal(.pipelineApplied(try Self.mcpPipelineSummary(record.projectedPipeline, db: db)), projectId: id, commandId: envelope.commandId, at: at, db: db)
                try Self.recordChangedSchedulerFlags(from: flags, commandId: envelope.commandId, at: at, db: db)
                let reply = CommandReply(commandId: envelope.commandId, seq: try Self.seq(db), result: .ok)
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
                return reply
            }
        } catch let error as CommandError {
            return try saveMCPRefusal(error, envelope: envelope, request: request, durable: selection != nil)
        } catch let error as StoreError {
            let reply = Self.failure(error, commandId: envelope.commandId)
            guard case .error(let failure) = reply.result else { return reply }
            if case .commandIdConflict = error { return reply }
            return try saveMCPRefusal(failure, envelope: envelope, request: request, durable: selection != nil)
        }
    }
    private func saveMCPRefusal(_ failure: CommandError, envelope: CommandEnvelope, request: Data, durable: Bool) throws -> CommandReply {
        let reply = CommandReply(commandId: envelope.commandId, seq: nil, result: .error(failure))
        if durable {
            try database.write { db in
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
            }
        }
        return reply
    }

    private func readMCPCatalog(projectPath: String) throws -> [McpServerRef] {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &directory), directory.boolValue else {
            throw CommandError(code: "project_missing", message: "Папка проекта недоступна; список MCP прочитать нельзя.")
        }
        var servers: [McpServerRef] = []
        for (file, source) in [(URL(fileURLWithPath: projectPath).appendingPathComponent(MCPConfigFile.relativePath), McpServerRef.Source.project), (personalMCPConfig, .personal)] {
            do {
                for url in [file.deletingLastPathComponent(), file] {
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw MCPConfigError.symlink }
                }
                let attributes: [FileAttributeKey: Any]
                do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { continue }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= DaemonWire.maxPipelineBytes else { throw MCPConfigError.unreadable }
                let data = try Data(contentsOf: file)
                guard data.count <= DaemonWire.maxPipelineBytes else { throw MCPConfigError.unreadable }
                let definitions = try MCPConfigFile.definitions(json: data, source: source.rawValue)
                guard definitions.count <= 1_024, definitions.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 256 && !$0.name.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) }) else { throw MCPConfigError.unreadable }
                servers += definitions.map { .init(name: $0.name, source: source) }
            } catch {
                throw CommandError(code: "mcp_config_unreadable", message: source == .project ? "Не удалось прочитать MCP проекта. Проверьте .cursor/mcp.json." : "Не удалось прочитать личные MCP. Проверьте ~/.cursor/mcp.json.", params: ["source": source.rawValue])
            }
        }
        return servers
    }
}
