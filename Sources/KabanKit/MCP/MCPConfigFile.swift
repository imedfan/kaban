import Foundation

public enum MCPConfigError: Error, Equatable {
    case symlink
    case unreadable
}

public struct MCPInstalledFile: Equatable, Sendable {
    public var previous: Data?
    public var excludeAdded: Bool
    public init(previous: Data?, excludeAdded: Bool) {
        self.previous = previous
        self.excludeAdded = excludeAdded
    }
}

public enum MCPConfigFile {
    public static let relativePath = ".cursor/mcp.json"
    private static let excludeLine = ".cursor/mcp.json"

    public static func definitions(json: Data, source: String) throws -> [MCPServerDefinition] {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { throw MCPConfigError.unreadable }
        return try servers.keys.sorted().map { name in
            guard let body = servers[name] as? [String: Any] else { throw MCPConfigError.unreadable }
            if let url = body["url"] as? String, !url.isEmpty {
                return MCPServerDefinition(name: name, source: source, endpoint: url)
            }
            if let command = body["command"] as? String, !command.isEmpty {
                return MCPServerDefinition(name: name, source: source, endpoint: command)
            }
            throw MCPConfigError.unreadable
        }
    }

    public static func install(cloneRoot: URL, generated: String) throws -> MCPInstalledFile {
        let cursor = cloneRoot.appendingPathComponent(".cursor", isDirectory: true)
        let file = cursor.appendingPathComponent("mcp.json")
        if isSymlink(cursor) || isSymlink(file) { throw MCPConfigError.symlink }
        if !FileManager.default.fileExists(atPath: cursor.path) {
            try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        }
        let previous = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        try Data(generated.utf8).write(to: file, options: .atomic)
        let excludeAdded = previous == nil && addExclude(cloneRoot)
        return MCPInstalledFile(previous: previous, excludeAdded: excludeAdded)
    }

    public static func restore(cloneRoot: URL, installed: MCPInstalledFile) throws {
        let file = cloneRoot.appendingPathComponent(relativePath)
        if isSymlink(file) || isSymlink(file.deletingLastPathComponent()) { throw MCPConfigError.symlink }
        if let previous = installed.previous {
            try previous.write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        if installed.excludeAdded { removeExclude(cloneRoot) }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func addExclude(_ root: URL) -> Bool {
        let info = root.appendingPathComponent(".git/info", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return false }
        if !FileManager.default.fileExists(atPath: info.path) {
            try? FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        }
        let exclude = info.appendingPathComponent("exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        if current.split(separator: "\n").contains(Substring(excludeLine)) { return false }
        let next = current.isEmpty || current.hasSuffix("\n") ? current + excludeLine + "\n" : current + "\n" + excludeLine + "\n"
        try? next.write(to: exclude, atomically: true, encoding: .utf8)
        return true
    }

    private static func removeExclude(_ root: URL) {
        let exclude = root.appendingPathComponent(".git/info/exclude")
        guard var lines = try? String(contentsOf: exclude, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) else { return }
        guard let index = lines.firstIndex(of: excludeLine) else { return }
        lines.remove(at: index)
        try? (lines.joined(separator: "\n") + "\n").write(to: exclude, atomically: true, encoding: .utf8)
    }
}
