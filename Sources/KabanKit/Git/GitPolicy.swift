import Foundation
import KabanProtocol

// `EffectiveGitPolicy`, `ConditionalGitRule` and `StageCommitter` live in KabanProtocol (arch. v0.11.6 §2, §8.4);
// the resolver and the checks stay here.
public extension EffectiveGitPolicy {
    /// Rules allowed for a run that entered the stage with `returnReason`: `allowed` plus the matching `conditional` rules.
    func allowed(for returnReason: ReturnReason?) -> [GitRule] {
        guard let reason = returnReason?.rawValue else { return allowed }
        var out = allowed
        for rule in conditional where rule.returnReason == reason {
            for r in rule.allowed where !out.contains(where: { $0.rule == r.rule }) { out.append(r) }
        }
        return out
    }

    /// `true` when the agent may run `command` in a run that entered the stage with `returnReason`.
    /// Rules match by word prefix (arch. v0.11.10 §8.4): `restore` covers `restore --staged x`, not vice versa.
    /// Hard invariants first, then any covering `denied` rule (deny beats allow), then any covering allowed rule.
    func allows(_ command: String, returnReason: ReturnReason? = nil) -> Bool {
        let c = GitPolicyResolver.normalize(command)
        if GitPolicyResolver.hardInvariant(for: c) != nil { return false }
        if denied.contains(where: { GitPolicyResolver.covers($0.rule, c) }) { return false }
        return allowed(for: returnReason).contains { GitPolicyResolver.covers($0.rule, c) }
    }
}

public enum GitPolicyResolver {
    public static let readCommands = ["status", "diff", "log", "show"]
    public static let standardWriteCommands = ["add", "commit", "restore --staged"]
    public static let permissiveCommands = ["stash", "rebase", "reset"]

    /// Catalog of known git commands (first words), in display order; sent as `PipelineSummary.gitCommandCatalog`
    /// (arch. v0.11.10 §8.4) and used for `git_unknown_command`. Hard-invariant-only commands (`push`, `remote`, `config`,
    /// `tag`, `update-ref`, `symbolic-ref`, `filter-branch`) are deliberately absent: they are never "not in preset".
    public static let gitCommandCatalog: [String] = [
        "status", "diff", "log", "show", "add", "commit", "restore", "stash", "rebase", "reset", "cherry-pick",
        "checkout", "switch", "branch", "fetch", "blame", "grep", "ls-files", "rev-parse", "show-ref", "reflog", "mv", "rm",
        "clean", "apply", "describe", "shortlog", "notes", "bisect", "revert", "worktree", "submodule", "am", "format-patch",
        "cat-file", "ls-tree", "merge-base",
    ]
    public static let knownCommands: Set<String> = Set(gitCommandCatalog)

    // MARK: Hard invariants (arch. v0.11.10 §8.2, spec v0.8.10 §1.5)

    /// Ids on the wire, in `HardInvariant.all` order; always all seven, for every stage.
    public static let hardInvariants: [String] = HardInvariant.all

    /// Matcher of one hard-invariant id. Patterns live only here (the protocol carries ids).
    public struct HardInvariantMatcher: Sendable {
        public var id: String
        /// Human-readable patterns, for docs and the report.
        public var patterns: [String]
        let test: @Sendable ([String]) -> Bool
        public func matches(_ rule: String) -> Bool { test(GitPolicyResolver.words(rule)) }
    }

    /// Commands where a short `-f` (also inside clusters like `-fd`) means "force" (arch. v0.11.12 §8.2, spec v0.8.12 §1.5).
    /// Elsewhere `-f` is an ordinary option (`grep -f`, `blame -f`, `ls-files -f`) and is not an invariant.
    public static let shortForceCommands: Set<String> = ["checkout", "switch", "add", "rm", "mv", "clean", "worktree", "submodule"]

    /// Checked in the canonical order `HardInvariant.all`; the first match names the id (arch. v0.11.13 §8.2):
    /// `push --force` → `push`, `checkout -f main` → `force`, `branch -f x` → `foreign_refs` (no short force for `branch`).
    /// `kaban_dir` has no git matcher: writes to `.kaban/` are blocked by `/git/check` and Seatbelt. `notes`, `fetch` and
    /// `worktree` targets have no static pattern either; `/git/check` checks them at call time.
    public static let hardInvariantMatchers: [HardInvariantMatcher] = [
        .init(id: HardInvariant.push, patterns: ["push …"]) { $0.first == "push" },
        .init(id: HardInvariant.remote, patterns: ["remote …"]) { $0.first == "remote" },
        .init(id: HardInvariant.config, patterns: ["config …"]) { $0.first == "config" },
        .init(id: HardInvariant.tag, patterns: ["tag …"]) { $0.first == "tag" },
        .init(id: HardInvariant.force,
              patterns: ["--force* on any command (prefix, incl. rebase --force-rebase)",
                         "-f (also in short clusters like -fd) on checkout, switch, add, rm, mv, clean, worktree, submodule",
                         "clean without -n/--dry-run (clean, clean -d/-x/-i …)"]) { w in
            guard let cmd = w.first else { return false }
            let args = optionArgs(w)
            if args.contains(where: { $0.hasPrefix("--force") }) { return true }
            if shortForceCommands.contains(cmd) && args.contains(where: { shortCluster($0, hasAnyOf: "f", consuming: shortValueOptions(cmd)) }) { return true }
            // v0.11.13 §8.2: `clean -i` and `clean.requireForce=false` delete without `-f`, so only a dry run passes.
            if cmd == "clean" { return !args.contains { $0 == "--dry-run" || shortCluster($0, hasAnyOf: "n", consuming: "e") } }
            return false
        },
        .init(id: HardInvariant.foreignRefs,
              patterns: ["update-ref …", "symbolic-ref …", "filter-branch …", "reflog expire …",
                         "branch -d/-D/-f/-m/-M/-C, --delete, --move (also in short clusters)",
                         "checkout -B …", "switch -C …",
                         "checkout/switch/rebase … main (also refs/heads/main, <remote>/main, main~n, main^)"]) { w in
            guard let cmd = w.first else { return false }
            if ["update-ref", "symbolic-ref", "filter-branch"].contains(cmd) { return true }
            if cmd == "reflog", w.dropFirst().first == "expire" { return true }
            let args = optionArgs(w)
            switch cmd {
            case "branch":
                return args.contains { longOption($0, abbreviates: "--delete", minimum: "--del") || longOption($0, abbreviates: "--move", minimum: "--mov") || shortCluster($0, hasAnyOf: "dDfmMC", consuming: "cC") }
            case "checkout":
                return args.contains { shortCluster($0, hasAnyOf: "B", consuming: "bB") } || args.contains(where: namesMain)
            case "switch":
                return args.contains { shortCluster($0, hasAnyOf: "C", consuming: "cC") } || args.contains(where: namesMain)
            case "rebase":
                return args.contains { word in
                    if let equal = word.firstIndex(of: "="),
                       longOption(String(word[..<equal]), abbreviates: "--onto", minimum: "--on") {
                        return namesMain(String(word[word.index(after: equal)...]))
                    }
                    return namesMain(word)
                }
            default:
                return false
            }
        },
    ]

    /// Id of the hard invariant `rule` (a policy rule or a normalized command) violates, if any.
    public static func hardInvariant(for rule: String) -> String? {
        hardInvariantMatchers.first { $0.matches(rule) }?.id
    }
    public static func violatesHardInvariant(_ rule: String) -> Bool { hardInvariant(for: rule) != nil }

    static func words(_ rule: String) -> [String] { normalize(rule).split(separator: " ").map(String.init) }
    /// Words after the subcommand up to `--` (after it come paths, not options).
    static func optionArgs(_ w: [String]) -> [String] { Array(w.dropFirst().prefix { $0 != "--" }) }
    /// Scan short options until an option consumes the rest as its value. `-qBtask1`
    /// contains B, while `-bfeature` contains b and a branch name, not a force flag.
    static func shortCluster(_ word: String, hasAnyOf letters: String, consuming: String = "") -> Bool {
        guard word.hasPrefix("-"), !word.hasPrefix("--"), word.count > 1 else { return false }
        for option in word.dropFirst() {
            guard option.isLetter else { return false }
            if letters.contains(option) { return true }
            if consuming.contains(option) { return false }
        }
        return false
    }
    static func shortValueOptions(_ command: String) -> String {
        switch command {
        case "checkout", "worktree": "bB"
        case "switch": "cC"
        case "clean": "e"
        default: ""
        }
    }
    /// Only the supported, unambiguous spelling family, not arbitrary prefix matches.
    static func longOption(_ word: String, abbreviates canonical: String, minimum: String) -> Bool {
        word.hasPrefix(minimum) && canonical.hasPrefix(word)
    }
    static func namesMain(_ word: String) -> Bool {
        var w = Substring(word)
        if let cut = w.firstIndex(where: { "~^@".contains($0) }) { w = w[..<cut] }
        return w == "main" || w.hasSuffix("/main")
    }

    // MARK: Rules

    public static func normalize(_ rule: String) -> String {
        rule.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Word-prefix match (arch. v0.11.10 §8.4): `rule` covers `command` when its words are a prefix of the command's words.
    public static func covers(_ rule: String, _ command: String) -> Bool {
        let r = words(rule), c = words(command)
        return !r.isEmpty && r.count <= c.count && Array(c.prefix(r.count)) == r
    }

    public static func isKnown(_ rule: String) -> Bool {
        guard let first = words(rule).first else { return false }
        return knownCommands.contains(first)
    }

    public static func presetCommands(_ preset: GitPreset) -> [String] {
        switch preset {
        case .strict: readCommands
        case .standard: readCommands + standardWriteCommands
        case .permissive: readCommands + standardWriteCommands + permissiveCommands
        }
    }

    public enum GitDecision: Sendable, Hashable { case allow, deny }

    /// Final decision and `source` of one rule from its per-layer decisions, in order preset → project → stage
    /// (inside a layer: allow before deny); `nil` when no layer mentions the rule. Arch. v0.11.9–v0.11.10 §8.4:
    /// a deny on any layer beats an allow (a later allow, e.g. a stage `extend` after a project `deny`, changes nothing),
    /// and `source` is the LAST layer that changed the rule's final state; repeating the same decision does not count.
    /// Hence `allowed` gets the first allowing layer and `denied` the first denying one. Presets only allow.
    public static func decide(_ history: [(GitRuleSource, GitDecision)]) -> (decision: GitDecision, source: GitRuleSource)? {
        var result: (decision: GitDecision, source: GitRuleSource)?
        for (layer, d) in history {
            let next: GitDecision = result?.decision == .deny ? .deny : d   // deny is sticky
            if next != result?.decision { result = (next, layer) }
        }
        return result
    }

    /// Policy of a stage, independent of the run: unconditional rules in `allowed`, `extend` with
    /// `when: return_reason == …` in `conditional` (never merged into `allowed`, arch. v0.11.6 §8.4).
    /// Every rule carries its layer, decided by `decide(_:)`; `conditional` is always `stage`; `hardInvariants` = all ids.
    /// An allowed rule covered (word prefix) by any denied rule or hitting a hard invariant is dropped (deny beats allow).
    /// Use `allowed(for:)` / `allows(_:returnReason:)` for a concrete run.
    public static func resolve(project: ProjectGitPolicy, stage: StageConfig) -> EffectiveGitPolicy {
        resolve(project: project, stageLayer: stage)
    }

    /// Preset + project layers only, no stage (`PipelineSummary.projectGitPolicy`, arch. v0.11.10 §8.4):
    /// sources are only `preset`/`project`, no `conditional`, not read-only.
    public static func resolveProject(_ project: ProjectGitPolicy) -> EffectiveGitPolicy {
        resolve(project: project, stageLayer: nil)
    }

    static func resolve(project: ProjectGitPolicy, stageLayer stage: StageConfig?) -> EffectiveGitPolicy {
        var history: [String: [(GitRuleSource, GitDecision)]] = [:]
        var allowOrder: [String] = [], denyOrder: [String] = []
        func record(_ r: String, _ layer: GitRuleSource, _ d: GitDecision) {
            let n = normalize(r)
            guard !n.isEmpty else { return }
            history[n, default: []].append((layer, d))
            if d == .allow, !allowOrder.contains(n) { allowOrder.append(n) }
            if d == .deny, !denyOrder.contains(n) { denyOrder.append(n) }
        }
        presetCommands(project.preset).forEach { record($0, .preset, .allow) }
        project.allow.forEach { record($0, .project, .allow) }
        project.deny.forEach { record($0, .project, .deny) }
        var conditionalExtend: [String] = []
        if let o = stage?.git {
            if o.when == nil { o.extend.forEach { record($0, .stage, .allow) } }
            else { o.extend.map(normalize).forEach { if !$0.isEmpty, !conditionalExtend.contains($0) { conditionalExtend.append($0) } } }
            o.deny.forEach { record($0, .stage, .deny) }   // stage denies always apply: narrowing is never conditional
        }
        func final(_ r: String) -> (decision: GitDecision, source: GitRuleSource)? { history[r].flatMap { decide($0) } }

        let readOnly = stage?.isReadOnly ?? false
        var denied = denyOrder.compactMap { r in final(r).flatMap { $0.decision == .deny ? GitRule(r, source: $0.source) : nil } }
        // v0.11.17 §8.4: a read-only stage lists what the project policy (preset + project) allowed and is not reading
        // as `denied` with `source: stage` (UI: «сужено до чтения»), after the regular denies; project denies keep `project`.
        // A rule already closed by a listed deny (exact or word prefix) is not repeated.
        if readOnly {
            for r in resolve(project: project, stageLayer: nil).allowed
            where !readCommands.contains(where: { covers($0, r.rule) }) && !denied.contains(where: { covers($0.rule, r.rule) }) {
                denied.append(GitRule(r.rule, source: .stage))
            }
            // v0.11.19 §8.4: a command outside `gitCommandCatalog` in a read-only stage's `extend` (with or without `when`)
            // is never allowed there — "unknown" is not "reads" (`replace`, `gc`, `prune`) — and is listed as a stage deny.
            // Hard invariants stay only in `hardInvariants`.
            for r in (stage?.git?.extend ?? []).map(normalize)
            where !r.isEmpty && !isKnown(r) && !violatesHardInvariant(r) && !denied.contains(where: { covers($0.rule, r) }) {
                denied.append(GitRule(r, source: .stage))
            }
        }
        func permitted(_ r: String) -> Bool {
            !violatesHardInvariant(r) && !denied.contains { covers($0.rule, r) }
                && (!readOnly || readCommands.contains { covers($0, r) })
        }
        let allowed = allowOrder.compactMap { r in
            final(r).flatMap { $0.decision == .allow && permitted(r) ? GitRule(r, source: $0.source) : nil }
        }
        var conditional: [ConditionalGitRule] = []
        if let reason = stage?.git?.when?.returnReason {
            let extra = conditionalExtend.filter { r in permitted(r) && !allowed.contains { covers($0.rule, r) } }
                .map { GitRule($0, source: .stage) }
            if !extra.isEmpty { conditional.append(ConditionalGitRule(returnReason: reason.rawValue, allowed: extra)) }
        }
        return EffectiveGitPolicy(preset: project.preset, allowed: allowed, denied: denied, hardInvariants: hardInvariants,
                                  conditional: conditional,
                                  committer: project.preset == .strict ? .daemonOnly : .agentWithSafetyCommit, readOnly: readOnly)
    }
}
