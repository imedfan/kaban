import Foundation
import KabanProtocol

/// Comparison of one `system/init` display name with the catalog. No branch invents a match.
public enum ModelObservation: Equatable, Sendable {
    case confirmed
    case substituted(requestedName: String, actualName: String)
    case unconfirmed
}

public enum ModelCatalogMatcher {
    /// Accept the BE-22 human listing and the legacy tab-separated adapter format.
    /// Unknown non-empty lines fail closed and must not replace stored rows.
    public static func parseListModels(_ text: String) -> [ModelInfo]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let content = lines.filter { !$0.isEmpty }
        guard !content.isEmpty else { return nil }
        var rows: [ModelInfo] = []
        var seen: Set<String> = []
        let humanListing = content.first == "Available models"
        for (index, line) in content.enumerated() {
            if humanListing && index == 0 { continue }
            if humanListing && index == content.count - 1 && line.hasPrefix("Tip: use --model <id> (or /model <id> in interactive mode) to switch.") { continue }
            let lower = line.lowercased()
            if line.contains("@") || lower.contains("error") || lower.contains("authentication") || lower.contains("not logged")
                || lower.contains("token") || lower.contains("secret") || lower.contains("key") {
                return nil
            }
            let columns = humanListing ? line.components(separatedBy: " - ") : line.components(separatedBy: "\t")
            let parts = columns.map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[0].contains(" "), seen.insert(parts[0]).inserted else { return nil }
            let id = ModelID(rawValue: parts[0])
            let forbidden = !PipelineValidator.hasExplicitModel(id)
            rows.append(ModelInfo(id: id, name: parts[1], pool: .om, needsReview: !forbidden, forbidden: forbidden))
        }
        return rows.isEmpty ? nil : rows
    }

    /// The requested id must have one catalog row. The actual display name must equal that row's name
    /// and must not also be another row's name. A known different name is substitution. Anything else is unconfirmed.
    public static func observe(requestedId: ModelID, actualName: String?, rows: [ModelInfo]) -> ModelObservation {
        let actual = actualName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let visible = rows.filter { !$0.forbidden }
        let requested = visible.filter { $0.id == requestedId }
        guard requested.count == 1, !actual.isEmpty else { return .unconfirmed }
        let named = visible.filter { $0.name == actual }
        guard named.count == 1, named[0].id == requestedId, requested[0].name == actual else {
            if named.count == 1, requested[0].name != actual {
                return .substituted(requestedName: requested[0].name, actualName: actual)
            }
            return .unconfirmed
        }
        return .confirmed
    }
}
