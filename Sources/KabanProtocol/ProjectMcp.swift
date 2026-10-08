import Foundation

/// Safe diagnostic only: configuration bodies, endpoints and credentials stay in the daemon.
public struct McpPreflightIssue: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case unexpected, unresolvable }
    public var kind: Kind
    public var name: String
    public init(kind: Kind, name: String) { self.kind = kind; self.name = name }
}
