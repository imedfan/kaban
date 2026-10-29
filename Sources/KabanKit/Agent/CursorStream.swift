import Foundation
import CoreFoundation
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
    /// Redacted or raw NDJSON line that produced each event, in event order. One line may yield two events.
    public var sources: [String]
    public init(events: [AgentEvent], diagnostics: [CursorStreamDiagnostic], sources: [String] = []) {
        self.events = events
        self.diagnostics = diagnostics
        self.sources = sources
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

    /// Continue a chunk that ended mid-line. The next `append` owns only the new bytes.
    public mutating func resume(remainder: Data, skipping: Bool) {
        line = remainder
        self.skipping = skipping
    }

    public var remainder: Data { line }
    public var skippingRemainder: Bool { skipping }

    public mutating func append(_ chunk: Data) -> CursorStreamBatch {
        var events: [AgentEvent] = []
        var diagnostics: [CursorStreamDiagnostic] = []
        var sources: [String] = []
        for byte in chunk {
            if skipping {
                if byte == 10 { skipping = false }
                continue
            }
            if byte == 10 {
                consume(line, events: &events, diagnostics: &diagnostics, sources: &sources)
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
        return CursorStreamBatch(events: events, diagnostics: diagnostics, sources: sources)
    }

    /// Flush a final unterminated NDJSON record once the process has exited.
    public mutating func finish() -> CursorStreamBatch {
        var batch = CursorStreamBatch(events: [], diagnostics: [])
        if !skipping { consume(line, events: &batch.events, diagnostics: &batch.diagnostics, sources: &batch.sources) }
        line.removeAll(); skipping = false
        return batch
    }

    private mutating func consume(_ raw: Data, events: inout [AgentEvent], diagnostics: inout [CursorStreamDiagnostic], sources: inout [String]) {
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
        let before = events.count
        let lineText = String(decoding: data, as: UTF8.self)
        switch type {
        case "system":
            let subtype = object["subtype"] as? String
            guard subtype == "init" else {
                diagnostics.append(CursorStreamDiagnostic(kind: .unknown))
                return
            }
            let model = nonEmpty(object["model"])
            let session = nonEmpty(object["session_id"])
            if let session { observedSessionId = session }
            events.append(.initialized(modelName: model, sessionId: session))
        case "thinking":
            // BE-22 emits delta/completed even in print mode. Do not expose private reasoning.
            return
        case "assistant", "user":
            let text = messageText(object)
            guard !text.isEmpty else { return }
            events.append(.message(role: type, text: text))
        case "tool_call":
            guard let event = toolEvent(object) else {
                diagnostics.append(CursorStreamDiagnostic(kind: .unknown))
                return
            }
            events.append(event)
        case "result":
            let isError = object["is_error"] as? Bool ?? false
            let subtype = object["subtype"] as? String
            events.append(.result(ok: !isError && subtype != "error", durationMs: integer(object["duration_ms"])))
            if isError || subtype == "error" {
                let error = object["error"] as? [String: Any]
                let message = nonEmpty(object["error"]) ?? nonEmpty(error?["message"]) ?? nonEmpty(object["result"]) ?? nonEmpty(object["message"]) ?? ""
                let code = nonEmpty(object["code"]) ?? nonEmpty(error?["code"])
                if code != nil || !message.isEmpty { events.append(.error(code: code, message: message)) }
            }
            if let usage = object["usage"] as? [String: Any] {
                events.append(.usage(inputTokens: token(usage, "input_tokens", "inputTokens"), outputTokens: token(usage, "output_tokens", "outputTokens")))
            }
        case "error":
            events.append(.error(code: nonEmpty(object["code"]), message: (object["message"] as? String) ?? ""))
        default:
            diagnostics.append(CursorStreamDiagnostic(kind: .unknown))
        }
        if events.count > before {
            sources.append(contentsOf: Array(repeating: lineText, count: events.count - before))
        }
    }

    private func toolEvent(_ object: [String: Any]) -> AgentEvent? {
        let id = nonEmpty(object["call_id"]) ?? ""
        let payload = object["tool_call"] as? [String: Any] ?? [:]
        // Metadata (hookAdditionalContexts, startedAtMs, toolCallId…) are siblings.
        let names = payload.keys.filter { $0.hasSuffix("ToolCall") && payload[$0] is [String: Any] }
        guard names.count == 1, let name = names.first, let body = payload[name] as? [String: Any] else { return nil }
        let summary = String((body["args"] as? [String: Any]).flatMap { $0["command"] as? String }?.prefix(200) ?? "")
        if (object["subtype"] as? String) == "completed" {
            return .toolResult(id: id, ok: toolSucceeded(body), summary: summary)
        }
        return .toolCall(id: id, name: name, summary: summary)
    }

    private func toolSucceeded(_ body: [String: Any]) -> Bool {
        if body["error"] != nil { return false }
        guard let result = body["result"] as? [String: Any] else { return true }
        if result["error"] != nil || result["failure"] != nil { return false }
        let success = result["success"] as? [String: Any] ?? result
        if success["isError"] as? Bool == true { return false }
        if let code = integer(success["exitCode"]) ?? integer(success["exit_code"]), code != 0 { return false }
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
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return Int(exactly: number.doubleValue)
        }
        return nil
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
