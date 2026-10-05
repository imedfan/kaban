import Foundation

/// Разобранное событие харнеса для живого лога (§5 `tailLog`). UI не зависит от формата конкретного CLI.
public enum AgentEvent: Codable, Hashable, Sendable {
    /// `system/init`: отображаемое имя модели, по нему демон сверяет подмену (§6.4).
    case initialized(modelName: String?, sessionId: String?)
    case message(role: String, text: String)
    case toolCall(id: String, name: String, summary: String)
    case toolResult(id: String, ok: Bool, summary: String)
    case usage(inputTokens: Int?, outputTokens: Int?)
    case error(code: String?, message: String)
    case result(ok: Bool, durationMs: Int?)
}

public struct LogBatch: Codable, Hashable, Sendable {
    public var runId: RunID
    public var fromOffset: Int64
    public var nextOffset: Int64
    public var events: [AgentEvent]
    public init(runId: RunID, fromOffset: Int64, nextOffset: Int64, events: [AgentEvent]) {
        self.runId = runId; self.fromOffset = fromOffset; self.nextOffset = nextOffset; self.events = events
    }
}

/// Offsets count normalized AgentEvent records, not bytes or raw stdout lines. Unavailable
/// or expired logs are errors, not empty successful pages. A completed run may still have pages.
public struct LogPage: Codable, Hashable, Sendable {
    public var batch: LogBatch
    public var availableFromOffset: Int64
    public var endOffset: Int64
    public var isComplete: Bool
    public init(batch: LogBatch, availableFromOffset: Int64, endOffset: Int64, isComplete: Bool) {
        self.batch = batch; self.availableFromOffset = availableFromOffset
        self.endOffset = endOffset; self.isComplete = isComplete
    }
}
