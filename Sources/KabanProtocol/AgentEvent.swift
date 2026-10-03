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
