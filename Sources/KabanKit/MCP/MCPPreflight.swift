import Foundation

public struct MCPServerDefinition: Equatable, Sendable {
    public var name: String
    public var source: String
    public var endpoint: String
    public var configurationJSON: String?
    public init(name: String, source: String, endpoint: String, configurationJSON: String? = nil) {
        self.name = name
        self.source = source
        self.endpoint = endpoint
        self.configurationJSON = configurationJSON
    }
}

public enum MCPPreflightBlock: Equatable, Sendable {
    case unexpected(String)
    case unresolvable(String)
}

public struct MCPPreflightDecision: Equatable, Sendable {
    public var names: [String]
    public var configJSON: String
    public var warnings: [String]
    public var block: MCPPreflightBlock?
    public init(names: [String], configJSON: String, warnings: [String], block: MCPPreflightBlock?) {
        self.names = names
        self.configJSON = configJSON
        self.warnings = warnings
        self.block = block
    }
}

public enum MCPPreflight {
    public static let tokenReference = "${env:KABAN_RUN_TOKEN}"
    public static func allowedNames(stageServers: [String], allowlist: Set<String>) -> [String] {
        stageServers.reduce(into: [AgentConfig.boardMcpServer]) { names, name in
            if allowlist.contains(name), !names.contains(name) { names.append(name) }
        }
    }

    /// The run config before `mcp list`: the board server with `${env:KABAN_RUN_TOKEN}` plus selected, allowlisted servers.
    /// `block` is set only for a config that cannot be built. The raw token is never copied.
    public static func plan(stageServers: [String], allowlist: Set<String>, definitions: [MCPServerDefinition], boardURL: String) -> MCPPreflightDecision {
        let names = allowedNames(stageServers: stageServers, allowlist: allowlist)
        var warnings: [String] = []
        var block: MCPPreflightBlock?
        for server in stageServers where server != AgentConfig.boardMcpServer && !allowlist.contains(server) {
            warnings.append("mcp_not_allowlisted:\(server)")
        }
        var servers: [String: [String: Any]] = [
            AgentConfig.boardMcpServer: [
                "url": boardURL,
                "headers": ["Authorization": "Bearer \(tokenReference)"],
            ],
        ]
        if definitions.contains(where: { $0.name == AgentConfig.boardMcpServer && $0.endpoint != boardURL }) {
            block = .unresolvable(AgentConfig.boardMcpServer)
        }
        for name in names where name != AgentConfig.boardMcpServer {
            let matches = definitions.filter { $0.name == name }
            let bodies = Set(matches.map { $0.configurationJSON ?? $0.endpoint })
            guard bodies.count == 1, let definition = matches.first, !definition.endpoint.isEmpty else {
                block = block ?? .unresolvable(name)
                continue
            }
            if let json = definition.configurationJSON,
               let body = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                servers[name] = body
            } else {
                servers[name] = definition.endpoint.contains("://") ? ["url": definition.endpoint] : ["command": definition.endpoint]
            }
        }
        let config = (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys])) ?? Data("{}".utf8)
        return MCPPreflightDecision(names: names, configJSON: String(decoding: config, as: UTF8.self), warnings: warnings, block: block)
    }

    /// Compares what the CLI lists with the planned names. An extra name wins over every other block.
    public static func check(_ plan: MCPPreflightDecision, listOutput: String, listExit: Int32) -> MCPPreflightDecision {
        var decision = plan
        if let listed = parseList(listOutput, exit: listExit) {
            let extra = listed.subtracting(plan.names).sorted()
            let missing = Set(plan.names).subtracting(listed).sorted()
            if let name = extra.first { decision.block = .unexpected(name) }
            else if let name = missing.first { decision.block = decision.block ?? .unresolvable("missing:\(name)") }
        } else {
            decision.block = decision.block ?? .unresolvable("mcp list")
        }
        return decision
    }

    /// Builds the run config from the stage selection and the allowlist. A bad `mcp list` blocks the run.
    /// The result never contains `--approve-mcps` and never copies a raw token.
    public static func decide(stageServers: [String], allowlist: Set<String>, definitions: [MCPServerDefinition], boardURL: String, listOutput: String, listExit: Int32) -> MCPPreflightDecision {
        check(plan(stageServers: stageServers, allowlist: allowlist, definitions: definitions, boardURL: boardURL), listOutput: listOutput, listExit: listExit)
    }

    /// `name<TAB>source` lines only. Any other text is unreadable and must not be treated as an empty allow.
    private static func parseList(_ output: String, exit: Int32) -> Set<String>? {
        guard exit == 0 else { return nil }
        var names: Set<String> = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            names.insert(parts[0])
        }
        return names.isEmpty ? nil : names
    }
}
