import Foundation

/// The transport carries the existing command and event DTOs without another task model.
/// Subscription pages cover the global journal; project filtering belongs to the consumer.
public struct DaemonRequest: Codable, Hashable, Sendable {
    public enum Operation: Codable, Hashable, Sendable {
        case snapshot
        case subscribe(fromSeq: Seq, limit: Int)
        case command(CommandEnvelope)
        case capabilities
        case synchronize
        case ephemeral(after: EphemeralCursor, limit: Int)
        case readLog(runId: RunID, fromOffset: Int64, limit: Int)
    }
    public var protocolVersion: Int
    public var operation: Operation
    public init(_ operation: Operation) {
        protocolVersion = KabanCoding.protocolVersion
        self.operation = operation
    }
}

public struct DaemonResponse: Codable, Hashable, Sendable {
    public enum Result: Codable, Hashable, Sendable {
        case snapshot(Snapshot)
        case events(JournalPage)
        case command(CommandReply)
        case error(CommandError)
        case capabilities(DaemonCapabilities)
        case replacement(SnapshotReplacement)
        case ephemeral(EphemeralPage)
        case log(LogPage)
    }
    public var protocolVersion: Int
    public var result: Result
    public init(_ result: Result) {
        protocolVersion = KabanCoding.protocolVersion
        self.result = result
    }
}

/// latestSeq is the durable high-water mark, including deleted journal entries.
/// A partial page advances only through its last event, never through latestSeq.
public struct JournalPage: Codable, Hashable, Sendable {
    public var fromSeq: Seq
    public var latestSeq: Seq
    public var events: [EventEnvelope]
    public var resyncRequired: Bool
    public init(fromSeq: Seq, latestSeq: Seq, events: [EventEnvelope], resyncRequired: Bool = false) {
        self.fromSeq = fromSeq; self.latestSeq = latestSeq
        self.events = events; self.resyncRequired = resyncRequired
    }
}

public protocol DaemonTransport: Sendable {
    func exchange(_ request: DaemonRequest) async throws -> DaemonResponse
}

public enum DaemonTransportError: Error, Equatable, Sendable {
    case connectionLost
    case timedOut
    case invalidReply
    case payloadTooLarge
    case bufferOverflow
}

public enum DaemonWire {
    public static let machService = "app.kaban.agent"
    public static let maxPageSize = 256
    public static let maxMessageBytes = 8 * 1_024 * 1_024
    public static let maxPipelineBytes = 1_024 * 1_024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try KabanCoding.makeEncoder().encode(value)
        guard data.count <= maxMessageBytes else { throw DaemonTransportError.payloadTooLarge }
        return data
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxMessageBytes else { throw DaemonTransportError.payloadTooLarge }
        return try KabanCoding.makeDecoder().decode(type, from: data)
    }
}
