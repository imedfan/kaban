import Foundation
import KabanProtocol

/// A classified Cursor failure. Unknown text stays `.unknown` and is not coerced into a limit.
public enum CursorLimitClass: Equatable, Sendable {
    case rateLimit
    case usageExhausted(ModelPool?)
    case modelUnavailable
    case runnerAuth
    case unknown
}

public enum CursorLimitClassifier {
    public static let cooldownSteps: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60]
    public static let probeInterval: TimeInterval = 10 * 60
    public static let unknownReset: TimeInterval = 6 * 60 * 60

    /// Empty text is not an error. A pool is used only for usage exhaustion; it is never invented.
    public static func classify(_ text: String, pool: ModelPool?) -> CursorLimitClass? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("spendlimithit") || lower.contains("usage limit") || lower.contains("usage_limit") {
            return .usageExhausted(pool)
        }
        if lower.contains("resource_exhausted") || lower.contains("not available in the slow pool") {
            return .modelUnavailable
        }
        if lower.contains("rate limit") || lower.contains("rate_limit") || lower.contains("too many requests") {
            return .rateLimit
        }
        if lower.contains("authentication failed") || lower.contains("invalid api key") || lower.contains("unauthorized") {
            return .runnerAuth
        }
        return .unknown
    }

    /// The next cooldown while a flag is already active uses the following step. A missing flag starts at 15 minutes.
    public static func cooldown(after step: Int?) -> (step: Int, seconds: TimeInterval) {
        let next = min(max((step ?? 0) + 1, 1), cooldownSteps.count)
        return (next, cooldownSteps[next - 1])
    }

    public static func resetDate(in text: String) -> Date? {
        let pattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: String(text[range])) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: String(text[range]))
    }

    /// Drops a diagnostic that carries a secret. The stored phrase is not the original text.
    public static func redact(_ text: String) -> String {
        let lower = text.lowercased()
        if text.contains("@") || lower.contains("token") || lower.contains("secret") || lower.contains("key") || lower.contains("sk-") {
            return "Неклассифицированная ошибка."
        }
        return String(text.prefix(500))
    }
}
