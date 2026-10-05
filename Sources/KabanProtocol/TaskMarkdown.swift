import Foundation

/// The single-body convention used by the task editor and command receiver.
/// The original Markdown is preserved; an ordinary description is not acceptance criteria.
public enum TaskMarkdown {
    public static let acceptanceCriteriaSeparator = "\n\n## Критерии приёмки\n"

    public static func acceptanceCriteria(in body: String) -> String? {
        guard let range = body.range(of: acceptanceCriteriaSeparator, options: .backwards) else { return nil }
        return String(body[range.upperBound...])
    }

    public static func hasAcceptanceCriteria(in body: String) -> Bool {
        guard let criteria = acceptanceCriteria(in: body) else { return false }
        return !criteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
