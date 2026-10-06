import Foundation
import KabanProtocol

/// Replaces secret-shaped substrings. A diagnostic that merely mentions a token keeps its other words.
enum SecretText {
    static let placeholder = "<redacted>"
    private static let patterns: [NSRegularExpression] = [
        #"KABAN_RUN_TOKEN=\S+"#,
        #"Bearer\s+\S+"#,
        #"sk-[A-Za-z0-9]{8,}"#,
        #"ghp_[A-Za-z0-9]{8,}"#,
        #"gho_[A-Za-z0-9]{8,}"#,
        #"github_pat_[A-Za-z0-9_]{8,}"#,
        #"xox[bp]-[A-Za-z0-9-]{8,}"#,
        #"AKIA[0-9A-Z]{8,}"#,
        #"glpat-[A-Za-z0-9\-]{8,}"#,
        #"AIza[A-Za-z0-9_\-]{8,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redact(_ text: String, extras: [String] = []) -> String {
        var result = text
        for extra in extras where extra.count >= 12 {
            result = result.replacingOccurrences(of: extra, with: placeholder)
        }
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            guard range.location != NSNotFound else { continue }
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: placeholder)
        }
        return result
    }

    static func redact(_ event: AgentEvent, extras: [String] = []) -> AgentEvent {
        switch event {
        case .initialized(let model, let session):
            return .initialized(modelName: model.map { redact($0, extras: extras) }, sessionId: session.map { redact($0, extras: extras) })
        case .message(let role, let text):
            return .message(role: role, text: redact(text, extras: extras))
        case .toolCall(let id, let name, let summary):
            return .toolCall(id: redact(id, extras: extras), name: redact(name, extras: extras), summary: redact(summary, extras: extras))
        case .toolResult(let id, let ok, let summary):
            return .toolResult(id: redact(id, extras: extras), ok: ok, summary: redact(summary, extras: extras))
        case .error(let code, let message):
            return .error(code: code, message: redact(message, extras: extras))
        case .usage, .result:
            return event
        }
    }

    static func redactFile(_ path: String, extras: [String] = []) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let text = redact(String(decoding: data, as: UTF8.self), extras: extras)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
