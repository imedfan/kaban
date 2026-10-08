import Foundation

public struct MCPServerDefinition: Equatable, Sendable {
    public var name: String
    public var source: String
    public var endpoint: String
    public init(name: String, source: String, endpoint: String) {
        self.name = name
        self.source = source
        self.endpoint = endpoint
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
}

public enum MCPPreflight {
    public static let tokenReference = "${env:KABAN_RUN_TOKEN}"
    public static func allowedNames(stageServers: [String], allowlist: Set<String>) -> [String] {
        stageServers.reduce(into: [AgentConfig.boardMcpServer]) { names, name in
            if allowlist.contains(name), !names.contains(name) { names.append(name) }
        }
    }

    /// Builds the run config from the stage selection and the allowlist. A bad `mcp list` blocks the run.
    /// The result never contains `--approve-mcps` and never copies a raw token.
    public static func decide(stageServers: [String], allowlist: Set<String>, definitions: [MCPServerDefinition], boardURL: String, listOutput: String, listExit: Int32) -> MCPPreflightDecision {
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
            let endpoints = Set(definitions.filter { $0.name == name }.map(\.endpoint))
            guard endpoints.count == 1, let endpoint = endpoints.first, !endpoint.isEmpty else {
                block = block ?? .unresolvable(name)
                continue
            }
            servers[name] = endpoint.contains("://") ? ["url": endpoint] : ["command": endpoint]
        }
        let config = (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers])) ?? Data("{}".utf8)
        let json = String(decoding: config, as: UTF8.self)
        if let listed = parseList(listOutput, exit: listExit) {
            let extra = listed.subtracting(names).sorted()
            let missing = Set(names).subtracting(listed).sorted()
            if let name = extra.first { block = .unexpected(name) }
            else if let name = missing.first { block = block ?? .unresolvable("missing:\(name)") }
        } else {
            block = block ?? .unresolvable("mcp list")
        }
        return MCPPreflightDecision(names: names, configJSON: json, warnings: warnings, block: block)
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
