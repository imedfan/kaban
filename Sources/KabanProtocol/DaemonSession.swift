import Foundation

/// Local transport state, not daemon scheduler state. Only connected permits new UI commands.
public enum DaemonConnectionState: Codable, Hashable, Sendable {
    case connecting
    case synchronizing
    case connected
    case reconnecting(lastSeq: Seq?)
    case disconnected(CommandError)
}

/// Volatile position in a daemon incarnation. This offset is never a journal seq.
public struct EphemeralCursor: Codable, Hashable, Sendable {
    public var sessionId: UUID
    public var offset: Int64
    public init(sessionId: UUID, offset: Int64) { self.sessionId = sessionId; self.offset = offset }
}

public struct EphemeralEnvelope: Codable, Hashable, Sendable {
    public var cursor: EphemeralCursor
    /// Deliver journal through this barrier BEFORE this event. Does not allocate a seq.
    public var afterSeq: Seq
    public var at: Date
    public var event: EphemeralEvent
    public init(cursor: EphemeralCursor, afterSeq: Seq, at: Date, event: EphemeralEvent) {
        self.cursor = cursor; self.afterSeq = afterSeq; self.at = at; self.event = event
    }
}

public struct EphemeralPage: Codable, Hashable, Sendable {
    public var fromCursor: EphemeralCursor
    public var nextCursor: EphemeralCursor
    public var latestCursor: EphemeralCursor
    public var events: [EphemeralEnvelope]
    /// Restart, retention or cursor ahead: no partial replay; obtain a replacement snapshot.
    public var resetRequired: Bool
    public init(fromCursor: EphemeralCursor, nextCursor: EphemeralCursor, latestCursor: EphemeralCursor,
                events: [EphemeralEnvelope], resetRequired: Bool = false) {
        self.fromCursor = fromCursor; self.nextCursor = nextCursor; self.latestCursor = latestCursor
        self.events = events; self.resetRequired = resetRequired
    }
}

/// Durable state and current volatile values captured under the live publisher's lock.
/// Resume journal at snapshot.seq and ephemeral delivery at cursor, never at latest journal seq.
public struct SnapshotReplacement: Codable, Hashable, Sendable {
    public var snapshot: Snapshot
    public var cursor: EphemeralCursor
    public var current: [EphemeralEnvelope]
    public init(snapshot: Snapshot, cursor: EphemeralCursor, current: [EphemeralEnvelope]) {
        self.snapshot = snapshot; self.cursor = cursor; self.current = current
    }
}

/// No credentials, tokens, argv or arbitrary inherited environment on the wire.
/// nil selects daemon discovery; an explicit path must be an absolute executable path.
public struct CursorEnvironment: Codable, Hashable, Sendable {
    public var executablePath: String?
    public init(executablePath: String?) { self.executablePath = executablePath }
}

public struct WIPRestore: Codable, Hashable, Sendable {
    public var taskId: TaskID
    public var runId: RunID
    public var wipRef: String
    public init(taskId: TaskID, runId: RunID, wipRef: String) {
        self.taskId = taskId; self.runId = runId; self.wipRef = wipRef
    }
}
