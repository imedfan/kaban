import Foundation
import KabanProtocol

/// One of the two fields of a commit author, in wire order (`name` before `email`).
public enum GitIdentityField: String, CaseIterable, Comparable, Sendable {
    case name, email
    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// Raw author fields as found (explicit identity or a repository read); `nil` = not set at all.
public struct GitIdentityFields: Equatable, Sendable {
    public var name: String?
    public var email: String?
    public init(name: String? = nil, email: String? = nil) { self.name = name; self.email = email }
    public init(_ identity: GitIdentity) { self.init(name: identity.name, email: identity.email) }

    public subscript(field: GitIdentityField) -> String? {
        get { field == .name ? name : email }
        set { if field == .name { name = newValue } else { email = newValue } }
    }

    /// Variables that would make `git -C <repo>` look at another repository; dropped for the reader.
    static let repositoryLocatingVariables: Set<String> = ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"]

    /// Reads `user.name`/`user.email` once with the user's NORMAL git in the given repository —
    /// `git -C <repo> config --get user.name|user.email`, i.e. repo + global + system config as git resolves them
    /// (not `DaemonGit`'s hardened environment). `GIT_DIR`/`GIT_WORK_TREE`/`GIT_COMMON_DIR` are dropped so the answer
    /// is about this repository. Each field is `nil` when git has no value; values are returned as read (only git's own
    /// trailing newline removed) and validated by the resolver. Meant for project registration only.
    public static func fromRepository(at path: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment,
                                      executable: String = DaemonGit.executable) -> GitIdentityFields {
        let env = environment.filter { !repositoryLocatingVariables.contains($0.key) }
        func read(_ key: String) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = ["-C", path, "config", "--get", key]
            p.environment = env
            let out = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            var v = String(decoding: data, as: UTF8.self)
            if v.hasSuffix("\n") { v.removeLast() }   // only git's own terminator; inner line breaks fail validation
            return v
        }
        return GitIdentityFields(name: read("user.name"), email: read("user.email"))
    }
}

/// `addProject`/`setProjectIdentity` could not get a usable author (arch. v0.11.21 §8.2); maps 1:1 to `CommandError`
/// with code `identity_required` and `params` — nothing is created or changed.
/// Per field exactly one of: missing (not found, empty, or whitespace-only after trimming spaces/tabs), invalid (CR/LF/NUL
/// inside, also from git config on the first call without identity), or found (valid, trimmed). Rejected values never return.
public struct GitIdentityRequired: Error, Equatable, Sendable {
    public var missing: Set<GitIdentityField>
    public var invalid: Set<GitIdentityField>
    /// The fields that were present and valid (trimmed), so the client can prefill them.
    public var found: GitIdentityFields

    public init(missing: Set<GitIdentityField> = [], invalid: Set<GitIdentityField> = [], found: GitIdentityFields = .init()) {
        self.missing = missing; self.invalid = invalid; self.found = found
    }

    /// Classifies raw fields; `nil` when both are present and valid (then `found` is the identity).
    static func check(_ raw: GitIdentityFields) -> (identity: GitIdentity?, error: GitIdentityRequired?) {
        var e = GitIdentityRequired()
        for f in GitIdentityField.allCases {
            let original = raw[f] ?? ""
            let v = original.trimmingCharacters(in: .whitespaces)
            // CRLF is one Swift Character: inspect scalars before trimming.
            if original.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 || $0.value == 0 }) { e.invalid.insert(f) }
            else if v.isEmpty { e.missing.insert(f) }
            else { e.found[f] = v }
        }
        if e.missing.isEmpty && e.invalid.isEmpty, let n = e.found.name, let m = e.found.email {
            return (GitIdentity(name: n, email: m), nil)
        }
        return (nil, e)
    }

    /// `CommandError.params` (arch. v0.11.20 §8.2): `missing` / `invalid` = `name` | `email` | `name,email` (name first),
    /// `name` / `email` = found values. Keys that don't apply are omitted (no empty strings).
    public var params: [String: String] {
        var p: [String: String] = [:]
        func list(_ s: Set<GitIdentityField>) -> String { s.sorted().map(\.rawValue).joined(separator: ",") }
        if !missing.isEmpty { p["missing"] = list(missing) }
        if !invalid.isEmpty { p["invalid"] = list(invalid) }
        if let n = found.name { p["name"] = n }
        if let m = found.email { p["email"] = m }
        return p
    }

    /// What the daemon answers the command with.
    public var commandError: CommandError {
        var parts: [String] = []
        if !missing.isEmpty { parts.append("missing " + missing.sorted().map(\.rawValue).joined(separator: " and ")) }
        if !invalid.isEmpty { parts.append(invalid.sorted().map(\.rawValue).joined(separator: " and ") + " must be a single line") }
        return CommandError(code: CommandError.identityRequiredCode,
                            message: "Commit author required: " + parts.joined(separator: "; "), params: params)
    }
}

/// KabanKit side of the protocol's `GitIdentity { name, email }` (arch. v0.11.20 §8.2). The protocol type is a plain
/// value with a memberwise init, so validity is checked where it is used: at registration, at `setProjectIdentity`
/// and on every `DaemonGit` call. The daemon stores (and sends in `ProjectSummary.identity`) only `validated()` values.
extension GitIdentity {
    /// Trimmed copy (spaces/tabs at both ends), or `GitIdentityRequired` with per-field `missing`/`invalid`/`found`.
    /// Also the check for `setProjectIdentity`.
    public func validated() throws -> GitIdentity {
        let r = GitIdentityRequired.check(GitIdentityFields(self))
        if let error = r.error { throw error }
        return r.identity!
    }

    /// `["-c", "user.name=<name>", "-c", "user.email=<email>"]` (as is; `DaemonGit` passes a `validated()` copy).
    public var configArguments: [String] { ["-c", "user.name=\(name)", "-c", "user.email=\(email)"] }

    /// The author for a new project (`addProject`), pure: an explicit identity wins and must be valid (an empty or
    /// invalid field does NOT fall back to the repository); without it, the fields read from the repository (evaluated
    /// only then); otherwise `identity_required` with what was found.
    public static func resolveForProject(explicit: GitIdentity?,
                                         repository: @autoclosure () -> GitIdentityFields) throws -> GitIdentity {
        if let explicit { return try explicit.validated() }
        let r = GitIdentityRequired.check(repository())
        if let error = r.error { throw error }
        return r.identity!
    }

    /// `resolveForProject` reading the repository via `GitIdentityFields.fromRepository(at:)` only when no explicit
    /// identity is given.
    public static func resolveForProject(explicit: GitIdentity?, repositoryPath: String,
                                         environment: [String: String] = ProcessInfo.processInfo.environment,
                                         executable: String = DaemonGit.executable) throws -> GitIdentity {
        try resolveForProject(explicit: explicit,
                              repository: GitIdentityFields.fromRepository(at: repositoryPath, environment: environment,
                                                                           executable: executable))
    }
}
