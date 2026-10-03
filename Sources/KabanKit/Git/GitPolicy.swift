import Foundation
import KabanProtocol

/// Who makes the commits of a stage (§6.3).
public enum StageCommitter: String, Codable, Hashable, Sendable {
    /// `strict`: the agent never commits; the daemon makes a single commit from `complete_stage.summary` after green gates.
    case daemonOnly = "daemon_only"
    /// `standard` / `permissive`: the agent commits, the daemon adds a safety commit `kaban: <stage> <task>`.
    case agentWithSafetyCommit = "agent_with_safety_commit"
}

/// Final git policy of a stage = preset → project allow/deny → stage overrides (§8.4).
/// One-off `git_grant`s are argv-level and are checked at runtime by `/git/check` (M2), not here.
/// Rules are normalized subcommand forms such as `status`, `restore --staged`, `rebase`.
public struct EffectiveGitPolicy: Codable, Hashable, Sendable {
    public var preset: GitPreset
    public var allowed: [String]
    public var denied: [String]
    /// Hard invariants: shown with a lock in the UI, cannot be lifted by any preset or override.
    public var hardDenied: [String]
    public var committer: StageCommitter
    public var readOnly: Bool

    public func allows(_ rule: String) -> Bool {
        let r = GitPolicyResolver.normalize(rule)
        if GitPolicyResolver.violatesHardInvariant(r) { return false }
        return allowed.contains(r) && !denied.contains(r)
    }
}

public enum GitPolicyResolver {
    public static let readCommands = ["status", "diff", "log", "show"]
    public static let standardWriteCommands = ["add", "commit", "restore --staged"]
    public static let permissiveCommands = ["stash", "rebase", "reset"]

    /// Never allowed for the agent (§8.2, spec 1.5): it does not move `main`/foreign branches, push, touch remotes/config/tags.
    /// Branch-scoped checks (`rebase main`, foreign refs, `--force`) happen in `/git/check`; here we list rule names.
    public static let hardInvariants = ["push", "remote", "config", "tag", "branch -d", "branch -D", "branch --delete",
                                        "checkout main", "switch main", "rebase main", "--force"]

    /// Subcommands the policy editor knows; anything else in allow/extend/deny yields a warning.
    public static let knownCommands: Set<String> = Set(readCommands + standardWriteCommands + permissiveCommands + [
        "restore", "checkout", "switch", "branch", "cherry-pick", "fetch", "blame", "grep", "ls-files", "rev-parse",
        "show-ref", "reflog", "mv", "rm", "clean", "apply", "describe", "shortlog", "notes", "bisect", "revert",
        "worktree", "submodule", "am", "format-patch", "cat-file", "ls-tree", "merge-base",
    ])

    public static func normalize(_ rule: String) -> String {
        rule.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    public static func violatesHardInvariant(_ rule: String) -> Bool {
        let r = normalize(rule)
        let words = r.split(separator: " ").map(String.init)
        if words.contains("--force") { return true }
        for h in hardInvariants {
            let hw = h.split(separator: " ").map(String.init)
            if words.count >= hw.count && Array(words.prefix(hw.count)) == hw { return true }
        }
        return false
    }

    public static func isKnown(_ rule: String) -> Bool {
        guard let first = normalize(rule).split(separator: " ").first else { return false }
        return knownCommands.contains(String(first))
    }

    public static func presetCommands(_ preset: GitPreset) -> [String] {
        switch preset {
        case .strict: readCommands
        case .standard: readCommands + standardWriteCommands
        case .permissive: readCommands + standardWriteCommands + permissiveCommands
        }
    }

    /// - Parameter returnReason: why the task came back into this stage; activates `when: return_reason == …` overrides.
    public static func resolve(project: ProjectGitPolicy, stage: StageConfig, returnReason: ReturnReason?) -> EffectiveGitPolicy {
        var allowed = presetCommands(project.preset)
        var denied: [String] = []
        func add(_ r: String) { let n = normalize(r); if !allowed.contains(n) { allowed.append(n) } }
        func deny(_ r: String) { let n = normalize(r); if !denied.contains(n) { denied.append(n) } }

        project.allow.forEach(add)
        project.deny.forEach(deny)
        if let o = stage.git {
            let active = o.when.map { $0.returnReason == returnReason } ?? true
            if active { o.extend.forEach(add) }
            o.deny.forEach(deny)   // stage denies always apply: narrowing is never conditional
        }
        let readOnly = stage.isReadOnly
        if readOnly { allowed = allowed.filter { readCommands.contains($0) } }
        allowed = allowed.filter { !violatesHardInvariant($0) && !denied.contains($0) }
        return EffectiveGitPolicy(preset: project.preset, allowed: allowed, denied: denied, hardDenied: hardInvariants,
                                  committer: project.preset == .strict ? .daemonOnly : .agentWithSafetyCommit, readOnly: readOnly)
    }
}
