import Foundation
import KabanProtocol

/// A file in the task branch diff against its base (`git diff --name-status base...branch`, plus uncommitted files in `strict`).
public struct ChangedFile: Hashable, Sendable {
    public var path: String
    public var sizeBytes: Int64
    public var blob: String
    public var deleted: Bool
    public init(path: String, sizeBytes: Int64, blob: String, deleted: Bool = false) {
        self.path = path; self.sizeBytes = sizeBytes; self.blob = blob; self.deleted = deleted
    }
    public var ref: FileBlobRef { FileBlobRef(path: path, blob: blob) }
}

/// `suspicious_files` check over the whole task-branch diff (§8.2, UC-25). Pure; git plumbing lives in KabanGit.
public enum SuspiciousFilesScanner {
    /// - Parameter accepted: `task_accepted_file` pairs; the same path with a different blob fires again.
    public static func scan(_ files: [ChangedFile], policy: SuspiciousFilesPolicy, accepted: Set<FileBlobRef> = []) -> [SuspiciousFile] {
        var out: [SuspiciousFile] = []
        for f in files where !f.deleted {
            if accepted.contains(f.ref) { continue }
            if policy.allow.contains(where: { matches(pattern: $0, path: f.path) }) { continue }
            if let p = policy.patterns.first(where: { matches(pattern: $0, path: f.path) }) {
                out.append(SuspiciousFile(path: f.path, rule: .pattern, pattern: p, sizeBytes: f.sizeBytes, blob: f.blob))
            } else if f.sizeBytes > policy.maxFileBytes {
                out.append(SuspiciousFile(path: f.path, rule: .size, sizeBytes: f.sizeBytes, blob: f.blob))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Patterns without `/` match the file name in any directory (`.env*` matches `api/.env.local`);
    /// patterns with `/` match the whole path, where `*` stays inside one segment and `**` crosses segments.
    public static func matches(pattern: String, path: String) -> Bool {
        if pattern.contains("/") { return glob(Array(pattern), Array(path)) }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return glob(Array(pattern), Array(name))
    }

    static func glob(_ p: [Character], _ s: [Character]) -> Bool {
        // Iterative matcher with memo to stay linear-ish on long paths.
        var memo = [Int: Bool]()
        func m(_ i: Int, _ j: Int) -> Bool {
            let key = i * (s.count + 1) + j
            if let v = memo[key] { return v }
            var r: Bool
            if i == p.count {
                r = j == s.count
            } else if p[i] == "*" {
                let doubleStar = i + 1 < p.count && p[i + 1] == "*"
                let next = doubleStar ? i + 2 : i + 1
                r = m(next, j)
                if !r && j < s.count && (doubleStar || s[j] != "/") { r = m(i, j + 1) }
            } else if j < s.count && (p[i] == "?" ? s[j] != "/" : p[i] == s[j]) {
                r = m(i + 1, j + 1)
            } else {
                r = false
            }
            memo[key] = r
            return r
        }
        return m(0, 0)
    }

    /// `acceptSuspiciousFiles` must name exactly the current set (path + blob), otherwise `stale_suspicious_files`.
    public static func sameSet(_ current: [SuspiciousFile], _ shown: [FileBlobRef]) -> Bool {
        let a = Set(current.map { FileBlobRef(path: $0.path, blob: $0.blob) })
        return a == Set(shown) && a.count == current.count && shown.count == Set(shown).count
    }
}
