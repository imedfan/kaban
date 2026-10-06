import Foundation
import KabanProtocol

public struct CursorStreamDiagnostic: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case malformed
        case oversized
        case unknown
    }
    public var kind: Kind
    public init(kind: Kind) { self.kind = kind }
}

public struct CursorStreamBatch: Equatable, Sendable {
    public var events: [AgentEvent]
    public var diagnostics: [CursorStreamDiagnostic]
    public init(events: [AgentEvent], diagnostics: [CursorStreamDiagnostic]) {
        self.events = events
        self.diagnostics = diagnostics
    }
}

/// Incremental NDJSON parser. A bad or unknown line does not fail the rest of the run.
public struct CursorStreamParser: Sendable {
    public static let maxLineBytes = 1_048_576
    private var line = Data()
    private var skipping = false
    /// Set only from a non-empty `session_id` on `system/init`. A result event does not invent one.
    public private(set) var observedSessionId: String?

    public init() {}

    public mutating func append(_ chunk: Data) -> CursorStreamBatch {
        var events: [AgentEvent] = []
        var diagnostics: [CursorStreamDiagnostic] = []
        for byte in chunk {
            if skipping {
                if byte == 10 { skipping = false }
                continue
            }
            if byte == 10 {
                consume(line, events: &events, diagnostics: &diagnostics)
                line.removeAll(keepingCapacity: false)
                continue
            }
            if line.count >= Self.maxLineBytes {
                diagnostics.append(CursorStreamDiagnostic(kind: .oversized))
                line.removeAll(keepingCapacity: false)
                skipping = true
                continue
            }
            line.append(byte)
        }
        return CursorStreamBatch(events: events, diagnostics: diagnostics)
    }

    private mutating func consume(_ raw: Data, events: inout [AgentEvent], diagnostics: inout [CursorStreamDiagnostic]) {
        var data = raw
        if data.last == 13 { data.removeLast() }
        guard !data.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            diagnostics.append(CursorStreamDiagnostic(kind: .malformed))
            return
        }
        guard let type = object["type"] as? String else {
            diagnostics.append(CursorStreamDiagnostic(kind: .unknown))
            return
        }
        switch type {
        case "system":
            let subtype = object["subtype"] as? String
            guard subtype == nil || subtype == "init" else {
                diagnostics.append(CursorStreamDiagnostic(kind: .unknown))
                return
            }
            let model = nonEmpty(object["model"])
            let session = nonEmpty(object["session_id"])
            if let session { observedSessionId = session }
            events.append(.initialized(modelName: model, sessionId: session))
        case "assistant", "user":
            let text = messageText(object)
            guard !text.isEmpty else { return }
            events.append(.message(role: type, text: text))
        case "tool_call":
            events.append(toolEvent(object))
        case "result":
            let isError = object["is_error"] as? Bool ?? false
            let subtype = object["subtype"] as? String
            events.append(.result(ok: !isError && subtype != "error", durationMs: integer(object["duration_ms"])))
            if let usage = object["usage"] as? [String: Any] {
                events.append(.usage(inputTokens: token(usage, "input_tokens", "inputTokens"), outputTokens: token(usage, "output_tokens", "outputTokens")))
            }
        case "error":
            events.append(.error(code: nonEmpty(object["code"]), message: (object["message"] as? String) ?? ""))
        default:
            diagnostics.append(CursorStreamDiagnostic(kind: .unknown))
        }
    }

    private func toolEvent(_ object: [String: Any]) -> AgentEvent {
        let id = nonEmpty(object["call_id"]) ?? ""
        let payload = object["tool_call"] as? [String: Any] ?? [:]
        let name = payload.keys.sorted().first ?? ""
        let body = payload[name] as? [String: Any] ?? [:]
        let summary = String((body["args"] as? [String: Any]).flatMap { $0["command"] as? String }?.prefix(200) ?? "")
        if (object["subtype"] as? String) == "completed" {
            return .toolResult(id: id, ok: toolSucceeded(body), summary: summary)
        }
        return .toolCall(id: id, name: name, summary: summary)
    }

    private func toolSucceeded(_ body: [String: Any]) -> Bool {
        if body["error"] != nil { return false }
        guard let result = body["result"] as? [String: Any] else { return true }
        if result["error"] != nil { return false }
        if let code = integer(result["exitCode"]) ?? integer(result["exit_code"]), code != 0 { return false }
        return true
    }

    private func messageText(_ object: [String: Any]) -> String {
        if let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            let parts = content.compactMap { item -> String? in
                guard (item["type"] as? String) == "text" else { return nil }
                return item["text"] as? String
            }
            if !parts.isEmpty { return parts.joined() }
        }
        return (object["text"] as? String) ?? ""
    }

    /// Missing token fields stay nil. They are never reported as zero.
    private func token(_ usage: [String: Any], _ first: String, _ second: String) -> Int? {
        integer(usage[first]) ?? integer(usage[second])
    }

    private func integer(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite, value.rounded() == value { return Int(value) }
        return nil
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
