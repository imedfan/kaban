import XCTest
import KabanProtocol
@testable import KabanKit

final class GitPolicyTests: XCTestCase {
    func testPresetsAndOverrides() throws {
        let c = try XCTUnwrap(PipelineValidator.validate(yaml: try Fixtures.text("good-full.yaml"), context: .init(mcpAllowlist: ["github"])).config)
        let dev = try XCTUnwrap(c.stage("dev"))
        let policy = GitPolicyResolver.resolve(project: c.git, stage: dev)
        XCTAssertEqual(policy.allowed.map(\.rule), ["status", "diff", "log", "show", "add", "commit", "restore --staged", "stash"])
        // v0.11.6 §8.4: `extend` with `when:` is kept in `conditional`, never merged into `allowed`.
        XCTAssertEqual(policy.conditional, [ConditionalGitRule(returnReason: "merge_conflict", allowed: [GitRule("rebase", source: .stage)])])
        XCTAssertFalse(policy.allowed.contains { $0.rule == "rebase" })
        XCTAssertFalse(policy.allows("rebase"))
        XCTAssertFalse(policy.allows("rebase", returnReason: .returned))
        XCTAssertEqual(policy.committer, .agentWithSafetyCommit)
        XCTAssertTrue(policy.allows("rebase", returnReason: .mergeConflict))
        XCTAssertEqual(policy.allowed(for: .mergeConflict), policy.allowed + [GitRule("rebase", source: .stage)])
        XCTAssertFalse(policy.allows("push", returnReason: .mergeConflict))

        let review = try XCTUnwrap(c.stage("ai_review"))
        let ro = GitPolicyResolver.resolve(project: c.git, stage: review)
        XCTAssertEqual(ro.allowed.map(\.rule), ["status", "diff", "log", "show"])
        XCTAssertEqual(ro.conditional, [])
        XCTAssertTrue(ro.readOnly)

        let strict = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .strict), stage: dev)
        XCTAssertEqual(strict.committer, .daemonOnly)
        XCTAssertFalse(strict.allows("commit"))

        let permissive = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .permissive, deny: ["reset"]), stage: dev)
        XCTAssertTrue(permissive.allows("rebase"))
        XCTAssertFalse(permissive.allows("reset"))
        XCTAssertTrue(GitPolicyResolver.violatesHardInvariant("push origin main"))
        XCTAssertTrue(GitPolicyResolver.violatesHardInvariant("commit --force"))
        XCTAssertFalse(GitPolicyResolver.violatesHardInvariant("rebase"))
    }

    static func stage(_ git: StageGitOverride?, readOnly: Bool = false) -> StageConfig {
        StageConfig(id: "dev", kind: .agent, agent: AgentConfig(model: "m1", permissions: readOnly ? .readOnly : .write), git: git)
    }

    /// Conditional `extend` rules are filtered like unconditional ones: denies, hard invariants, read-only, duplicates.
    func testConditionalExtendFiltering() {
        let when = GitOverrideCondition(returnReason: .mergeConflict)
        let p = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .standard, deny: ["reset"]),
                                          stage: Self.stage(StageGitOverride(extend: ["rebase", "reset", "push", "commit", "stash"], when: when)))
        XCTAssertEqual(p.conditional, [ConditionalGitRule(returnReason: "merge_conflict",
                                                          allowed: [GitRule("rebase", source: .stage), GitRule("stash", source: .stage)])])
        XCTAssertFalse(p.allowed.contains { $0.rule == "rebase" })
        XCTAssertFalse(p.allows("reset", returnReason: .mergeConflict))
        // Read-only stage: conditional write rules vanish; an empty rule is not emitted.
        let ro = GitPolicyResolver.resolve(project: ProjectGitPolicy(), stage: Self.stage(StageGitOverride(extend: ["rebase"], when: when), readOnly: true))
        XCTAssertEqual(ro.conditional, [])
        // Without `when:` the extension is unconditional.
        let plain = GitPolicyResolver.resolve(project: ProjectGitPolicy(), stage: Self.stage(StageGitOverride(extend: ["rebase"])))
        XCTAssertTrue(plain.allowed.contains(GitRule("rebase", source: .stage)))
        XCTAssertEqual(plain.conditional, [])
    }

    // MARK: `source` (arch. v0.11.9 §8.4)

    /// Preset → project → stage chains. `source` = the last layer that changed the rule's final state, repeating the
    /// same decision does not count; a deny on any layer beats an allow; presets only allow.
    struct SourceCase {
        var name: String
        var preset: GitPreset = .standard
        var projectAllow: [String] = [], projectDeny: [String] = []
        var stageExtend: [String] = [], stageDeny: [String] = []
        var rule: String
        var expected: (GitPolicyResolver.GitDecision, GitRuleSource)
    }

    static let sourceCases: [SourceCase] = [
        // The three chains named in v0.11.9 §8.4.
        SourceCase(name: "(1) preset allows → stage denies", stageDeny: ["commit"], rule: "commit", expected: (.deny, .stage)),
        SourceCase(name: "(2) project denies → stage extends", projectDeny: ["add"], stageExtend: ["add"], rule: "add",
                   expected: (.deny, .project)),
        SourceCase(name: "(3) preset allows → stage repeats extend", stageExtend: ["status"], rule: "status", expected: (.allow, .preset)),
        // Further combinations.
        SourceCase(name: "preset only", rule: "diff", expected: (.allow, .preset)),
        SourceCase(name: "project repeats a preset allow", projectAllow: ["commit"], rule: "commit", expected: (.allow, .preset)),
        SourceCase(name: "project allow → stage repeats extend", projectAllow: ["stash"], stageExtend: ["stash"], rule: "stash",
                   expected: (.allow, .project)),
        SourceCase(name: "stage-only allow", stageExtend: ["rebase"], rule: "rebase", expected: (.allow, .stage)),
        SourceCase(name: "project allow → stage denies", projectAllow: ["cherry-pick"], stageDeny: ["cherry-pick"], rule: "cherry-pick",
                   expected: (.deny, .stage)),
        SourceCase(name: "preset allows → project denies → stage repeats deny", preset: .permissive, projectDeny: ["reset"],
                   stageDeny: ["reset"], rule: "reset", expected: (.deny, .project)),
        SourceCase(name: "project denies → stage extends and denies", projectDeny: ["add"], stageExtend: ["add"], stageDeny: ["add"],
                   rule: "add", expected: (.deny, .project)),
        SourceCase(name: "allow + deny inside the project layer", projectAllow: ["fetch"], projectDeny: ["fetch"], rule: "fetch",
                   expected: (.deny, .project)),
        SourceCase(name: "stage extends and denies the same rule", stageExtend: ["rebase"], stageDeny: ["rebase"], rule: "rebase",
                   expected: (.deny, .stage)),
        SourceCase(name: "project denies a rule no layer allowed", projectDeny: ["clean"], rule: "clean", expected: (.deny, .project)),
    ]

    func testSourceChainsPresetProjectStage() {
        for c in Self.sourceCases {
            let p = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: c.preset, allow: c.projectAllow, deny: c.projectDeny),
                                              stage: Self.stage(StageGitOverride(extend: c.stageExtend, deny: c.stageDeny)))
            let inAllowed = p.allowed.first { $0.rule == c.rule }, inDenied = p.denied.first { $0.rule == c.rule }
            switch c.expected.0 {
            case .allow:
                XCTAssertEqual(inAllowed?.source, c.expected.1, c.name); XCTAssertNil(inDenied, c.name)
                XCTAssertTrue(p.allows(c.rule), c.name)
            case .deny:
                XCTAssertEqual(inDenied?.source, c.expected.1, c.name); XCTAssertNil(inAllowed, c.name)
                XCTAssertFalse(p.allows(c.rule), c.name)
            }
        }
    }

    /// Deny beats allow on every layer, including for conditional (`when:`) extends and for the merge-conflict return.
    func testDenyBeatsAllow() {
        let when = GitOverrideCondition(returnReason: .mergeConflict)
        // A conditional extend cannot lift a project deny and never lists the denied rule in `conditional`.
        let p = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .permissive, deny: ["rebase"]),
                                          stage: Self.stage(StageGitOverride(extend: ["rebase", "stash"], when: when)))
        XCTAssertEqual(p.denied, [GitRule("rebase", source: .project)])
        XCTAssertFalse(p.allows("rebase")); XCTAssertFalse(p.allows("rebase", returnReason: .mergeConflict))
        XCTAssertFalse(p.conditional.flatMap(\.allowed).contains { $0.rule == "rebase" })
        // Same with a stage deny next to a conditional extend.
        let s = GitPolicyResolver.resolve(project: ProjectGitPolicy(),
                                          stage: Self.stage(StageGitOverride(extend: ["rebase"], deny: ["rebase"], when: when)))
        XCTAssertEqual(s.conditional, [])
        XCTAssertFalse(s.allows("rebase", returnReason: .mergeConflict))
        // Every rule is in at most one list.
        let all = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .permissive, allow: ["fetch"], deny: ["reset", "fetch"]),
                                            stage: Self.stage(StageGitOverride(extend: ["reset", "fetch"], deny: ["commit"])))
        XCTAssertTrue(Set(all.allowed.map(\.rule)).isDisjoint(with: all.denied.map(\.rule)))
        XCTAssertFalse(all.allowed.contains { GitPolicyResolver.violatesHardInvariant($0.rule) })
        XCTAssertEqual(all.denied.map(\.rule), ["reset", "fetch", "commit"])
        XCTAssertEqual(all.denied.map(\.source), [.project, .project, .stage])
    }

    /// `decide` on raw layer histories.
    func testDecide() {
        typealias D = GitPolicyResolver.GitDecision
        func check(_ h: [(GitRuleSource, D)], _ decision: D, _ source: GitRuleSource, line: UInt = #line) {
            let r = GitPolicyResolver.decide(h)
            XCTAssertEqual(r?.decision, decision, line: line); XCTAssertEqual(r?.source, source, line: line)
        }
        check([(.preset, .allow), (.stage, .deny)], .deny, .stage)                         // (1)
        check([(.project, .deny), (.stage, .allow)], .deny, .project)                      // (2)
        check([(.preset, .allow), (.stage, .allow)], .allow, .preset)                      // (3)
        check([(.preset, .allow), (.project, .deny), (.stage, .allow)], .deny, .project)
        check([(.preset, .allow), (.project, .deny), (.stage, .deny)], .deny, .project)
        check([(.project, .allow), (.project, .deny)], .deny, .project)
        check([(.stage, .allow)], .allow, .stage)
        XCTAssertNil(GitPolicyResolver.decide([]))
    }

    func testHardInvariantIdsAndConditionalSources() {
        let p = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .standard, allow: ["remote", "tag"]),
                                          stage: Self.stage(StageGitOverride(extend: ["rebase"], when: GitOverrideCondition(returnReason: .mergeConflict))))
        // v0.11.12 §8.2: always the seven stable ids, in the canonical order (= spec §1.5), for every stage.
        XCTAssertEqual(p.hardInvariants, ["push", "remote", "config", "tag", "force", "foreign_refs", "kaban_dir"])
        XCTAssertEqual(p.hardInvariants, HardInvariant.all)
        XCTAssertFalse(GitRuleSource.allCases.map(\.rawValue).contains("hard"))
        // A project allow of a hard invariant never shows up as allowed.
        XCTAssertFalse(p.allowed.contains { $0.rule == "remote" || $0.rule == "tag" })
        XCTAssertFalse(p.allows("remote add x y")); XCTAssertFalse(p.allows("tag v1"))
        XCTAssertTrue(p.conditional.flatMap(\.allowed).allSatisfy { $0.source == .stage })
        XCTAssertEqual(p.conditional.first?.allowed, [GitRule("rebase", source: .stage)])
        // v0.11.17: read-only narrowing moves the project policy's write rules from `allowed` to `denied` with `source: stage`.
        let ro = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .permissive), stage: Self.stage(nil, readOnly: true))
        XCTAssertEqual(ro.allowed, GitPolicyResolver.readCommands.map { GitRule($0, source: .preset) })
        XCTAssertEqual(ro.denied, ["add", "commit", "restore --staged", "stash", "rebase", "reset"].map { GitRule($0, source: .stage) })
        XCTAssertEqual(ro.hardInvariants, HardInvariant.all)
    }

    /// Id → matcher table (patterns only in KabanKit, arch. v0.11.13 §8.2). First match in canonical order; `nil` = no invariant.
    func testHardInvariantMatchers() {
        let cases: [(String, String?)] = [
            // push / remote / config / tag — whole subcommand.
            ("push", "push"), ("push origin main", "push"), ("push --force", "push"), ("push --force-with-lease", "push"),
            ("push --mirror", "push"), ("push origin --delete x", "push"), ("push -f", "push"),
            ("remote add o url", "remote"), ("config user.name x", "config"), ("tag v1", "tag"), ("tag -f v1", "tag"),
            // force: `--force*` on any command; short `-f` only on the eight "forcing" commands.
            ("commit --force", "force"), ("reset --force", "force"), ("checkout --force", "force"), ("switch --force-create x", "force"),
            ("checkout -f", "force"), ("checkout -fq x", "force"), ("switch -f x", "force"), ("add -f secret", "force"),
            ("rm -f x", "force"), ("rm -rf dir", "force"), ("mv -f a b", "force"), ("clean -f", "force"), ("clean -fd", "force"),
            ("clean -xdf", "force"), ("clean -nf", "force"),
            // v0.11.13: any `clean` without -n/--dry-run.
            ("clean", "force"), ("clean -d", "force"), ("clean -x", "force"), ("clean -i", "force"), ("clean -X", "force"),
            ("clean -- -n", "force"), ("rebase --force-rebase", "force"), ("worktree add -f x", "force"), ("worktree remove --force x", "force"),
            ("submodule update -f", "force"),
            // Canonical order: force is checked before foreign_refs.
            ("checkout -f main", "force"), ("switch -C x --force", "force"), ("branch --force x", "force"),
            ("branch -D --force x", "force"), ("rebase --force-rebase main", "force"),
            // foreign_refs.
            ("update-ref refs/heads/main HEAD", "foreign_refs"), ("symbolic-ref HEAD refs/heads/x", "foreign_refs"),
            ("filter-branch --tree-filter x", "foreign_refs"), ("reflog expire --all", "foreign_refs"),
            ("branch -d other", "foreign_refs"), ("branch -D other", "foreign_refs"), ("branch --delete other", "foreign_refs"),
            ("branch -f other HEAD", "foreign_refs"), ("branch -m new", "foreign_refs"), ("branch -M new", "foreign_refs"),
            ("branch -C a b", "foreign_refs"), ("branch --move a b", "foreign_refs"), ("branch -Dr x", "foreign_refs"),
            ("checkout -B x", "foreign_refs"), ("checkout -B x main", "foreign_refs"), ("switch -C x", "foreign_refs"),
            ("checkout main", "foreign_refs"), ("switch main", "foreign_refs"), ("rebase main", "foreign_refs"),
            ("rebase -i origin/main", "foreign_refs"), ("checkout refs/heads/main", "foreign_refs"), ("rebase main~2", "foreign_refs"),
            ("rebase main^", "foreign_refs"), ("checkout -b x main", "foreign_refs"),
            // Not invariants: other `-f` meanings, plain branch creation, read commands, /git/check-only commands.
            ("grep -f patterns.txt", nil), ("blame -f a.swift", nil), ("ls-files -f", nil), ("log -1", nil), ("commit -F msg.txt", nil),
            ("clean -n", nil), ("clean -nd", nil), ("clean -dn", nil), ("clean --dry-run -x", nil), ("clean -n -x -d", nil), ("branch -c a b", nil), ("checkout -b topic", nil), ("switch -c topic", nil),
            ("rebase", nil), ("rebase -i HEAD~3", nil), ("checkout feature-x", nil), ("branch", nil), ("branch -a", nil),
            ("branch new-topic", nil), ("reflog", nil), ("reflog show", nil), ("status", nil), ("checkout -- -f", nil),
            ("checkout mainline", nil), ("restore --staged x", nil), ("describe --tags", nil),
            ("notes add -m x", nil), ("fetch origin", nil), ("worktree add ../x", nil), ("cherry-pick -f", nil),
        ]
        for (rule, id) in cases { XCTAssertEqual(GitPolicyResolver.hardInvariant(for: rule), id, rule) }
        // Every id has a matcher except `kaban_dir` (blocked by /git/check and Seatbelt).
        XCTAssertEqual(GitPolicyResolver.hardInvariantMatchers.map(\.id), HardInvariant.all.filter { $0 != HardInvariant.kabanDir })
        // Hard-invariant-only commands are not in the catalog.
        for c in ["push", "remote", "config", "tag", "update-ref", "symbolic-ref", "filter-branch"] {
            XCTAssertFalse(GitPolicyResolver.gitCommandCatalog.contains(c), c)
        }
        XCTAssertEqual(Set(GitPolicyResolver.gitCommandCatalog).count, GitPolicyResolver.gitCommandCatalog.count, "no duplicates")
    }

    /// v0.11.10 §8.4: rules match by word prefix — `restore` covers `restore --staged`, not vice versa; deny beats allow.
    func testWordPrefixMatching() {
        XCTAssertTrue(GitPolicyResolver.covers("restore", "restore --staged"))
        XCTAssertTrue(GitPolicyResolver.covers("restore --staged", "restore --staged a.txt"))
        XCTAssertFalse(GitPolicyResolver.covers("restore --staged", "restore"))
        XCTAssertFalse(GitPolicyResolver.covers("restore --staged", "restore a.txt"))
        XCTAssertFalse(GitPolicyResolver.covers("re", "restore"), "whole words only")
        XCTAssertFalse(GitPolicyResolver.covers("", "status"))

        // Project denies `restore` → preset's `restore --staged` leaves `allowed` (protocol fixture case).
        let p = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .standard, allow: ["cherry-pick"], deny: ["restore"]),
                                          stage: Self.stage(StageGitOverride(extend: ["stash"])))
        XCTAssertFalse(p.allowed.contains { $0.rule == "restore --staged" })
        XCTAssertEqual(p.denied, [GitRule("restore", source: .project)])
        XCTAssertFalse(p.allows("restore --staged a.txt")); XCTAssertFalse(p.allows("restore a.txt"))
        XCTAssertTrue(p.allows("cherry-pick abc")); XCTAssertTrue(p.allows("stash"))
        // A stage extend of the covered rule does not lift it either.
        let s = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .standard, deny: ["restore"]),
                                          stage: Self.stage(StageGitOverride(extend: ["restore --staged"])))
        XCTAssertFalse(s.allowed.contains { $0.rule == "restore --staged" })
        XCTAssertFalse(s.allows("restore --staged x"))

        // Not vice versa: denying `restore --staged` keeps an allowed `restore`, but the narrower command is denied.
        let v = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .standard, allow: ["restore"], deny: ["restore --staged"]),
                                          stage: Self.stage(nil))
        XCTAssertEqual(v.allowed.first { $0.rule == "restore" }?.source, .project)
        XCTAssertFalse(v.allowed.contains { $0.rule == "restore --staged" })
        XCTAssertTrue(v.allows("restore a.txt"))
        XCTAssertFalse(v.allows("restore --staged a.txt"), "deny beats allow")
        // An allowed rule covers longer commands; hard invariants still win inside an allowed rule.
        let b = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .standard, allow: ["branch", "checkout"]), stage: Self.stage(nil))
        XCTAssertTrue(b.allows("branch new-topic")); XCTAssertTrue(b.allows("checkout feature-x"))
        XCTAssertFalse(b.allows("branch -D other")); XCTAssertFalse(b.allows("checkout main")); XCTAssertFalse(b.allows("checkout -f x"))
        // Conditional rules covered by a deny are dropped as well.
        let c = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .standard, deny: ["rebase"]),
                                          stage: Self.stage(StageGitOverride(extend: ["rebase -i", "stash"], when: GitOverrideCondition(returnReason: .mergeConflict))))
        XCTAssertEqual(c.conditional.first?.allowed, [GitRule("stash", source: .stage)])
        XCTAssertFalse(c.allows("rebase -i HEAD~2", returnReason: .mergeConflict))
    }

    /// `PipelineSummary.projectGitPolicy` (preset + project only) and `gitCommandCatalog` (arch. v0.11.10 §8.4).
    func testProjectGitPolicyAndCatalogInSummary() throws {
        let yaml = """
        version: 1
        git: { preset: standard, allow: [cherry-pick], deny: [restore] }
        stages:
          - { id: backlog, kind: queue, on_success: dev }
          - id: dev
            kind: agent
            agent: { model: m1 }
            git: { extend: [stash], deny: [commit] }
            on_success: merge
          - { id: merge, kind: merge, on_success: done }
          - { id: done, kind: terminal }
        """
        let v = PipelineValidator.validate(yaml: yaml)
        XCTAssertTrue(v.isValid, v.dump)
        let summary = try XCTUnwrap(v.config).summary(projectId: "p", versionHash: nil)
        let project = try XCTUnwrap(summary.projectGitPolicy)
        XCTAssertEqual(project.allowed, [GitRule("status", source: .preset), GitRule("diff", source: .preset), GitRule("log", source: .preset),
                                         GitRule("show", source: .preset), GitRule("add", source: .preset), GitRule("commit", source: .preset),
                                         GitRule("cherry-pick", source: .project)])
        XCTAssertEqual(project.denied, [GitRule("restore", source: .project)])
        XCTAssertEqual(project.conditional, []); XCTAssertFalse(project.readOnly)
        XCTAssertEqual(project.hardInvariants, HardInvariant.all); XCTAssertEqual(project.committer, .agentWithSafetyCommit)
        XCTAssertTrue((project.allowed + project.denied).allSatisfy { $0.source == .preset || $0.source == .project })
        // The stage layer only shows up in the stage's own policy.
        let dev = try XCTUnwrap(summary.stages.first { $0.id == "dev" }?.gitPolicy)
        XCTAssertTrue(dev.allowed.contains(GitRule("stash", source: .stage)))
        XCTAssertTrue(dev.denied.contains(GitRule("commit", source: .stage)))
        XCTAssertEqual(summary.gitCommandCatalog, GitPolicyResolver.gitCommandCatalog)
        XCTAssertEqual(Array(summary.gitCommandCatalog.prefix(11)),
                       ["status", "diff", "log", "show", "add", "commit", "restore", "stash", "rebase", "reset", "cherry-pick"])
        // "Not in preset" = catalog command neither allowed nor denied (prefix-aware).
        let notInPreset = summary.gitCommandCatalog.filter { c in
            !project.allowed.contains { GitPolicyResolver.covers($0.rule, c) } && !project.denied.contains { GitPolicyResolver.covers($0.rule, c) }
        }
        XCTAssertTrue(notInPreset.contains("stash")); XCTAssertFalse(notInPreset.contains("restore")); XCTAssertFalse(notInPreset.contains("add"))
        // Draft validation carries the same project policy.
        let draft = v.draftValidation(projectId: "p", contentHash: "h")
        XCTAssertEqual(draft.resolved?.projectGitPolicy, project)
        XCTAssertEqual(GitPolicyResolver.resolveProject(ProjectGitPolicy(preset: .strict)).committer, .daemonOnly)
    }

    /// v0.11.18 §8.4: a writing `extend` (with or without `when`) on a read-only stage is `git_readonly_extend`;
    /// v0.11.19: a command outside `gitCommandCatalog` there only gets `git_unknown_command` and becomes a stage deny.
    static let readOnlyExtendYAML = """
    version: 1
    stages:
      - { id: backlog, kind: queue, on_success: dev }
      - id: dev
        kind: agent
        agent: { model: m1 }
        git: { extend: [stash, commit, replace] }
        on_success: review
      - id: review
        kind: agent
        agent: { model: m1, permissions: read-only }
        git: { extend: [log --all, commit, status, restore --staged, replace, rebsae -i], deny: [diff, add] }
        on_success: audit
      - id: audit
        kind: agent
        agent: { model: m1, permissions: read-only }
        git: { extend: [rebase -i, push, show, gc --prune=now, update-ref HEAD x], when: return_reason == merge_conflict }
        on_success: merge
      - { id: merge, kind: merge, on_success: done }
      - { id: done, kind: terminal }
    """

    func testReadOnlyStageWritingExtendIsAnError() throws {
        let v = PipelineValidator.validate(yaml: Self.readOnlyExtendYAML)
        let ro = v.issues.filter { $0.code == ValidationCode.gitReadonlyExtend }
        XCTAssertEqual(ro.map(\.path), ["stages[2].git.extend[1]", "stages[2].git.extend[3]", "stages[3].git.extend[0]"], v.dump)
        XCTAssertEqual(ro.map(\.stageId), ["review", "review", "audit"])
        XCTAssertEqual(ro.map(\.params), [["cmd": "commit"], ["cmd": "restore"], ["cmd": "rebase"]])
        XCTAssertTrue(ro.allSatisfy { $0.severity == .error })
        // Reads in extend are fine; a hard invariant only gets `git_hard_invariant` (also when outside the catalog).
        XCTAssertNil(v.issues.first { $0.path == "stages[2].git.extend[0]" || $0.path == "stages[2].git.extend[2]" }, v.dump)
        XCTAssertEqual(v.issues.filter { $0.path == "stages[3].git.extend[1]" }.map(\.code), [ValidationCode.gitHardInvariant])
        XCTAssertEqual(v.issues.filter { $0.path == "stages[3].git.extend[4]" }.map(\.code), [ValidationCode.gitHardInvariant])
        XCTAssertNil(v.issues.first { $0.path == "stages[3].git.extend[2]" })
        // v0.11.19: outside the catalog on a read-only stage → ONLY the unknown-command warning, one message per line,
        // with or without `when`.
        for (path, cmd) in [("stages[2].git.extend[4]", "replace"), ("stages[2].git.extend[5]", "rebsae"),
                            ("stages[3].git.extend[3]", "gc")] {
            let here = v.issues.filter { $0.path == path }
            XCTAssertEqual(here.map(\.code), [ValidationCode.gitUnknownCommand], "\(path): \(v.dump)")
            XCTAssertEqual(here.first?.severity, .warning)
            XCTAssertEqual(here.first?.params, ["cmd": cmd])
        }
        // Writable stage: unchanged — an unknown command is a warning, nothing else.
        XCTAssertEqual(v.issues.filter { $0.path.hasPrefix("stages[1].") }.map(\.code), [ValidationCode.gitUnknownCommand], v.dump)
        XCTAssertEqual(v.issues.first { $0.path == "stages[1].git.extend[2]" }?.params, ["cmd": "replace"])
        XCTAssertFalse(v.isValid)
        XCTAssertNil(v.issues.first { $0.code == "readonly_violation" }, "unrelated runtime reason")

        // Explicit `deny` of a read-only stage resolves with `source: stage` (UI: «сужено до чтения»); the narrowing
        // does not repeat a rule the explicit deny already closes, and the offending extends never reach `allowed`.
        // v0.11.19: unknown extends come last, as `stage` denies (`replace`, `rebsae -i`); never in `allowed`.
        let c = try XCTUnwrap(v.config)
        let review = GitPolicyResolver.resolve(project: c.git, stage: try XCTUnwrap(c.stage("review")))
        XCTAssertEqual(review.denied, [GitRule("diff", source: .stage), GitRule("add", source: .stage),
                                       GitRule("commit", source: .stage), GitRule("restore --staged", source: .stage),
                                       GitRule("replace", source: .stage), GitRule("rebsae -i", source: .stage)])
        XCTAssertEqual(review.allowed.map(\.rule), ["status", "log", "show", "log --all"])
        let audit = GitPolicyResolver.resolve(project: c.git, stage: try XCTUnwrap(c.stage("audit")))
        // rebase -i: a known write on a read-only stage (validation error, absent at runtime); push / update-ref: hard
        // invariants (only in hardInvariants); show: already allowed → nothing conditional; gc (unknown, with `when`) →
        // unconditional stage deny.
        XCTAssertEqual(audit.conditional, [])
        XCTAssertEqual(audit.denied.filter { $0.source == .stage && !["add", "commit", "restore --staged"].contains($0.rule) },
                       [GitRule("gc --prune=now", source: .stage)])
        XCTAssertNil(audit.allowed.first { ["rebase", "push", "gc", "update-ref"].contains(String($0.rule.split(separator: " ")[0])) })
        XCTAssertEqual(audit.allowed(for: .mergeConflict), audit.allowed)
        // Writable stage: unknown extends are allowed as before.
        let dev = GitPolicyResolver.resolve(project: c.git, stage: try XCTUnwrap(c.stage("dev")))
        XCTAssertTrue(dev.allowed.contains(GitRule("replace", source: .stage)))
        XCTAssertNil(dev.denied.first { $0.rule == "replace" })
    }

    /// v0.11.19: an unknown read-only extend already closed by a deny is not repeated; a known read stays allowed.
    func testReadOnlyUnknownExtendDedup() {
        let project = ProjectGitPolicy(preset: .standard, allow: [], deny: ["replace"])
        let ro = GitPolicyResolver.resolve(project: project,
                                           stage: Self.stage(StageGitOverride(extend: ["replace --edit", "prune", "prune -n", "show"],
                                                                              deny: []), readOnly: true))
        XCTAssertEqual(ro.denied, [GitRule("replace", source: .project), GitRule("add", source: .stage),
                                   GitRule("commit", source: .stage), GitRule("restore --staged", source: .stage),
                                   GitRule("prune", source: .stage)])
        XCTAssertEqual(ro.allowed.map(\.rule), ["status", "diff", "log", "show"])
    }

    /// v0.11.17 §8.4: a read-only stage lists the project policy's non-read rules as `stage` denies, after the regular ones.
    func testReadOnlyNarrowingListsProjectWritesAsStageDenies() {
        let project = ProjectGitPolicy(preset: .standard, allow: ["log --all", "cherry-pick"], deny: ["restore"])
        let ro = GitPolicyResolver.resolve(project: project,
                                           stage: Self.stage(StageGitOverride(extend: ["rebase"], deny: ["commit --amend"]), readOnly: true))
        // Reads stay allowed (`log --all` is covered by `log`); project deny keeps `project`; `restore --staged` is
        // closed by the project's `restore` and not repeated; the stage's own `extend` is not part of the project policy.
        XCTAssertEqual(ro.allowed.map(\.rule), ["status", "diff", "log", "show", "log --all"])
        XCTAssertEqual(ro.denied, [GitRule("restore", source: .project), GitRule("commit --amend", source: .stage),
                                   GitRule("add", source: .stage), GitRule("commit", source: .stage), GitRule("cherry-pick", source: .stage)])
        XCTAssertFalse(ro.allows("commit -m x")); XCTAssertFalse(ro.allows("rebase")); XCTAssertTrue(ro.allows("log --all"))
        // Off-policy commands (not allowed by preset/project) stay out of both lists → client shows «нет в пресете».
        for off in ["rebase", "reset", "stash"] {
            XCTAssertFalse((ro.allowed + ro.denied).contains { $0.rule == off }, off)
        }
        // A writable stage with the same project policy gets no such denies.
        let rw = GitPolicyResolver.resolve(project: project, stage: Self.stage(nil))
        XCTAssertEqual(rw.denied, [GitRule("restore", source: .project)])
        // The project policy itself is never read-only.
        XCTAssertEqual(GitPolicyResolver.resolveProject(project).denied, [GitRule("restore", source: .project)])
    }

    /// The protocol sample (patch 2117ae7c, `Samples.pipeline`): project allows `stash` and denies `cherry-pick`,
    /// Dev narrows `stash` and extends `rebase` on `merge_conflict`; the read-only `test` stage inherits the project deny
    /// and lists the project's non-read rules as `stage` denies (v0.11.17 «сужено до чтения»).
    /// The resolver yields exactly the sample's policies.
    func testProtocolSampleGitPolicies() throws {
        let project = ProjectGitPolicy(preset: .standard, allow: ["stash"], deny: ["cherry-pick"])
        let dev = Self.stage(StageGitOverride(extend: ["rebase"], deny: ["stash"], when: GitOverrideCondition(returnReason: .mergeConflict)))
        let preset = ["status", "diff", "log", "show", "add", "commit", "restore --staged"].map { GitRule($0, source: .preset) }
        XCTAssertEqual(GitPolicyResolver.resolveProject(project),
                       EffectiveGitPolicy(preset: .standard, allowed: preset + [GitRule("stash", source: .project)],
                                          denied: [GitRule("cherry-pick", source: .project)], hardInvariants: HardInvariant.all,
                                          committer: .agentWithSafetyCommit, readOnly: false))
        XCTAssertEqual(GitPolicyResolver.resolve(project: project, stage: dev),
                       EffectiveGitPolicy(preset: .standard, allowed: preset,
                                          denied: [GitRule("cherry-pick", source: .project), GitRule("stash", source: .stage)],
                                          hardInvariants: HardInvariant.all,
                                          conditional: [ConditionalGitRule(returnReason: "merge_conflict", allowed: [GitRule("rebase", source: .stage)])],
                                          committer: .agentWithSafetyCommit, readOnly: false))
        let test = GitPolicyResolver.resolve(project: project, stage: Self.stage(nil, readOnly: true))
        XCTAssertEqual(test.denied.first, GitRule("cherry-pick", source: .project), "read-only stage keeps the inherited project deny")
        for off in ["rebase", "reset"] { XCTAssertFalse((test.allowed + test.denied).contains { $0.rule == off }, "\(off) is off-policy") }
        XCTAssertEqual(test,
                       EffectiveGitPolicy(preset: .standard, allowed: ["status", "diff", "log", "show"].map { GitRule($0, source: .preset) },
                                          denied: [GitRule("cherry-pick", source: .project)]
                                              + ["add", "commit", "restore --staged", "stash"].map { GitRule($0, source: .stage) },
                                          hardInvariants: HardInvariant.all, committer: .agentWithSafetyCommit, readOnly: true))
    }

    /// `git_hard_invariant` fires for every invariant id hit by a granting rule (project allow, stage extend, conditional extend);
    /// params stay empty (§4.1 text has no placeholders); denying an invariant is silent.
    func testValidatorHardInvariantsAndUnknownCommands() {
        let rules = ["push --force", "remote", "config core.x y", "tag", "update-ref", "branch -m x", "checkout -f", "filter-branch",
                     "reflog expire", "symbolic-ref"]
        let yaml = """
        version: 1
        git: { allow: [\(rules.joined(separator: ", "))], deny: [push, update-ref, frobnicate --x] }
        stages:
          - { id: backlog, kind: queue, on_success: dev }
          - id: dev
            kind: agent
            agent: { model: m1 }
            git: { extend: [switch main, clean -fd], when: return_reason == merge_conflict }
            on_success: merge
          - { id: merge, kind: merge, on_success: done }
          - { id: done, kind: terminal }
        """
        let v = PipelineValidator.validate(yaml: yaml)
        let hard = v.issues.filter { $0.code == ValidationCode.gitHardInvariant }
        XCTAssertEqual(hard.map(\.path), (0..<rules.count).map { "git.allow[\($0)]" } + ["stages[1].git.extend[0]", "stages[1].git.extend[1]"], v.dump)
        XCTAssertTrue(hard.allSatisfy { $0.params.isEmpty && $0.severity == .error })
        XCTAssertEqual(hard.first { $0.path == "git.allow[5]" }?.stageId, nil)
        XCTAssertEqual(hard.first { $0.path == "stages[1].git.extend[0]" }?.stageId, "dev")
        XCTAssertTrue(hard.first { $0.path == "git.allow[6]" }?.message.contains("force") ?? false)
        // deny: [push, update-ref] — no issue at all; unknown first word → warning with cmd = first word.
        XCTAssertNil(v.issues.first { $0.path == "git.deny[0]" || $0.path == "git.deny[1]" }, v.dump)
        let unknown = v.issues.first { $0.code == ValidationCode.gitUnknownCommand }
        XCTAssertEqual(unknown?.path, "git.deny[2]"); XCTAssertEqual(unknown?.params, ["cmd": "frobnicate"]); XCTAssertEqual(unknown?.severity, .warning)
    }
}

final class SuspiciousFilesTests: XCTestCase {
    let policy = SuspiciousFilesPolicy()

    func testPatternsAllowAndSize_SUSP01_SUSP02() {
        let files = [
            ChangedFile(path: ".env.local", sizeBytes: 212, blob: "a1b2c3"),
            ChangedFile(path: ".env.example", sizeBytes: 90, blob: "e0e0e0"),
            ChangedFile(path: "certs/server.pem", sizeBytes: 10, blob: "p1"),
            ChangedFile(path: "src/main.swift", sizeBytes: 10, blob: "s1"),
            ChangedFile(path: "assets/dump.bin", sizeBytes: 7_340_032, blob: "d4e5f6"),
            ChangedFile(path: "old/id_rsa", sizeBytes: 1, blob: "k", deleted: true),
        ]
        let found = SuspiciousFilesScanner.scan(files, policy: policy)
        XCTAssertEqual(found.map(\.path), [".env.local", "assets/dump.bin", "certs/server.pem"])
        XCTAssertEqual(found.map(\.rule), [.pattern, .size, .pattern])
        XCTAssertEqual(found[0].pattern, ".env*")

        // Accepted (path, blob) does not fire again; same path with a new blob does.
        let accepted: Set<FileBlobRef> = [FileBlobRef(path: ".env.local", blob: "a1b2c3"), FileBlobRef(path: "certs/server.pem", blob: "p1")]
        XCTAssertEqual(SuspiciousFilesScanner.scan(files, policy: policy, accepted: accepted).map(\.path), ["assets/dump.bin"])
        let changed = [ChangedFile(path: ".env.local", sizeBytes: 230, blob: "ffff01")]
        XCTAssertEqual(SuspiciousFilesScanner.scan(changed, policy: policy, accepted: accepted).map(\.path), [".env.local"])
    }

    func testGlob() {
        XCTAssertTrue(SuspiciousFilesScanner.matches(pattern: "*.key", path: "a/b/c.key"))
        XCTAssertFalse(SuspiciousFilesScanner.matches(pattern: "*.key", path: "a/b/c.keys"))
        XCTAssertTrue(SuspiciousFilesScanner.matches(pattern: "config/*.json", path: "config/a.json"))
        XCTAssertFalse(SuspiciousFilesScanner.matches(pattern: "config/*.json", path: "config/x/a.json"))
        XCTAssertTrue(SuspiciousFilesScanner.matches(pattern: "config/**.json", path: "config/x/a.json"))
        XCTAssertTrue(SuspiciousFilesScanner.matches(pattern: "id_?sa*", path: "id_rsa.pub"))
    }

    func testSameSet() {
        let cur = [SuspiciousFile(path: "a", rule: .pattern, sizeBytes: 1, blob: "1"), SuspiciousFile(path: "b", rule: .size, sizeBytes: 9, blob: "2")]
        XCTAssertTrue(SuspiciousFilesScanner.sameSet(cur, [FileBlobRef(path: "b", blob: "2"), FileBlobRef(path: "a", blob: "1")]))
        XCTAssertFalse(SuspiciousFilesScanner.sameSet(cur, [FileBlobRef(path: "a", blob: "1")]))
        XCTAssertFalse(SuspiciousFilesScanner.sameSet(cur, [FileBlobRef(path: "a", blob: "1"), FileBlobRef(path: "b", blob: "3")]))
    }
}
