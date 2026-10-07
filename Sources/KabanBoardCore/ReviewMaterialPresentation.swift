import Foundation
import KabanProtocol

/// Conservative parsing of the actual textual artifacts; unknown formats keep their source.
public enum ReviewMaterialPresentation {
    public struct FileChange: Equatable, Sendable {
        public let path: String
        public let additions: Int?
        public let deletions: Int?
        public let changes: Int?
        public let binary: Bool
    }
    public struct Commit: Equatable, Sendable { public let sha: String; public let subject: String }
    public static func files(_ text: String) -> [FileChange]? {
        guard text.utf8.count <= TaskDetailPresentation.largeTextBytes else { return nil }
        var result: [FileChange] = []
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 3, let add = Int(fields[0]), let del = Int(fields[1]), add >= 0, del >= 0, !fields[2].isEmpty {
                let total = add.addingReportingOverflow(del)
                guard !total.overflow else { return nil }
                result.append(.init(path: String(fields[2]), additions: add, deletions: del, changes: total.partialValue, binary: false)); continue
            }
            if fields.count == 3, fields[0] == "-", fields[1] == "-", !fields[2].isEmpty {
                result.append(.init(path: String(fields[2]), additions: nil, deletions: nil, changes: nil, binary: true)); continue
            }
            if line.range(of: #"^\s*\d+ files? changed(?:,.*)?$"#, options: .regularExpression) != nil { continue }
            guard let separator = line.range(of: " | ", options: .backwards) else { return nil }
            let path = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let source = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            if source.range(of: #"^Bin \d+ -> \d+ bytes$"#, options: .regularExpression) != nil {
                result.append(.init(path: path, additions: nil, deletions: nil, changes: nil, binary: true)); continue
            }
            guard source.range(of: #"^\d+(?:\s+[+-]+)?$"#, options: .regularExpression) != nil,
                  let total = source.split(whereSeparator: \.isWhitespace).first.flatMap({ Int($0) }) else { return nil }
            // git --stat scales +/- glyphs. They are not exact line counts.
            result.append(.init(path: path, additions: nil, deletions: nil, changes: total, binary: false))
        }
        return result.isEmpty ? nil : result
    }
    public static func commits(_ text: String) -> [Commit]? {
        guard text.utf8.count <= TaskDetailPresentation.largeTextBytes else { return nil }
        var result: [Commit] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let space = line.firstIndex(of: " ") else { return nil }
            let sha = String(line[..<space]), subject = String(line[line.index(after: space)...])
            guard [40, 64].contains(sha.count), sha.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
            result.append(.init(sha: sha, subject: subject))
        }
        return result.isEmpty ? nil : result
    }
    public static func conflictCount(_ card: TaskCard) -> Int? {
        card.bounceByReason["merge_conflict"].flatMap { $0 > 0 ? $0 : nil }
    }
}
