import Foundation
import XCTest
import KabanProtocol
@testable import KabanKit

/// Return rules of arch. v0.11.4–v0.11.5 §3.1 / §3.3 (spec v0.8.5 §1.3): a task is only *returned* to an agent stage
/// with readOnly == false; defaults are resolved by KabanKit and sent resolved in `StageSummary` / `PipelineSummary`.
final class ReturnRulesTests: XCTestCase {
    /// backlog → triage(ro) → spec → dev → review(ro) → check(gate) → human → merge → done
    static func pipeline(check: String = "", merge: String = "") -> String {
        """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: triage }
          - { id: triage, kind: agent, agent: { model: m1, permissions: read-only }, on_success: spec }
          - { id: spec, kind: agent, agent: { model: m1 }, on_success: dev }
          - { id: dev, kind: agent, agent: { model: m1 }, on_success: review }
          - { id: review, kind: agent, agent: { model: m1, permissions: read-only }, on_success: check }
          - { id: check, kind: gate, gates: [make check], \(check) on_success: human }
          - { id: human, kind: human, on_success: merge }
          - { id: merge, kind: merge, \(merge) on_success: done }
          - { id: done, kind: terminal }
        """
    }

    func valid(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) throws -> PipelineConfig {
        let v = PipelineValidator.validate(yaml: yaml)
        XCTAssertTrue(v.isValid, v.dump, file: file, line: line)
        return try XCTUnwrap(v.config, file: file, line: line)
    }

    // MARK: Rule 2/4 — on_fail defaults

    func testOnFailStageOmittedResolvesToNearestPrecedingWritableAgentStage() throws {
        let c = try valid(Self.pipeline(check: "on_fail: { limit: 2 },"))
        let check = try XCTUnwrap(c.stage("check"))
        XCTAssertEqual(check.onFail, FailReturn(stage: nil, limit: 2))
        // Skips read-only `review`, picks the nearer `dev` over `spec` along on_success.
        XCTAssertEqual(c.nearestWritableAgentStage(before: "check")?.id, "dev")
        XCTAssertEqual(check.failReturn(in: c), StageReturn(stage: "dev", limit: 2))
    }

    func testOnFailBlockOptionalAndLimitDefaultsTo3() throws {
        let noBlock = try valid(Self.pipeline())
        XCTAssertNil(noBlock.stage("check")?.onFail)
        XCTAssertEqual(noBlock.stage("check")?.failReturn(in: noBlock), StageReturn(stage: "dev", limit: 3))
        let empty = try valid(Self.pipeline(check: "on_fail: {},"))
        XCTAssertEqual(empty.stage("check")?.failReturn(in: empty), StageReturn(stage: "dev", limit: FailReturn.defaultLimit))
        let stageOnly = try valid(Self.pipeline(check: "on_fail: { stage: spec },"))
        XCTAssertEqual(stageOnly.stage("check")?.failReturn(in: stageOnly), StageReturn(stage: "spec", limit: 3))
        // Not a gate → no fail return at all.
        XCTAssertNil(noBlock.stage("dev")?.failReturn(in: noBlock))
    }

    // MARK: Rule 5 — on_conflict / requestChanges defaults

    func testOnConflictAndRequestChangesDefaultToFirstWritableAgentStage() throws {
        let c = try valid(Self.pipeline())
        XCTAssertEqual(c.firstAgentStage?.id, "triage", "first agent stage is read-only")
        XCTAssertEqual(c.firstWritableAgentStage?.id, "spec")
        XCTAssertEqual(c.defaultReturnStage, "spec")
        XCTAssertEqual(c.stage("merge")?.conflictReturn(in: c), StageReturn(stage: "spec", limit: ConflictReturn.defaultLimit))
        XCTAssertNil(c.stage("check")?.conflictReturn(in: c))
    }

    // MARK: Rule 3/5 — no_return_target

    func testNoWritableAgentStageIsNoReturnTargetForGateAndMerge() throws {
        for check in ["on_fail: { limit: 1 },", ""] {
            let yaml = """
            version: 1
            stages:
              - { id: backlog, kind: queue, on_success: review }
              - { id: review, kind: agent, agent: { model: m1, permissions: read-only }, on_success: check }
              - { id: check, kind: gate, gates: [make check], \(check) on_success: merge }
              - { id: merge, kind: merge, on_success: done }
              - { id: done, kind: terminal }
            """
            let v = PipelineValidator.validate(yaml: yaml)
            let failPath = check.isEmpty ? "stages[2].on_fail" : "stages[2].on_fail.stage"
            XCTAssertTrue(v.has(ValidationCode.noReturnTarget, at: failPath), v.dump)
            XCTAssertTrue(v.has(ValidationCode.noReturnTarget, at: "stages[3].on_conflict"), v.dump)
            // Plus the pipeline-level one for requestChanges (gate/merge exist), without stageId (v0.11.6 §3.1).
            XCTAssertTrue(v.has(ValidationCode.noReturnTarget, at: "stages"), v.dump)
            XCTAssertEqual(v.errors.map(\.code), Array(repeating: ValidationCode.noReturnTarget, count: 3), v.dump)
            XCTAssertEqual(v.errors.map(\.stageId), ["check", "merge", nil], "stageId = the stage owning the return")
            let c = try XCTUnwrap(v.config)
            XCTAssertNil(c.stage("check")?.failReturn(in: c))
            XCTAssertNil(c.stage("merge")?.conflictReturn(in: c))
            XCTAssertNil(c.defaultReturnStage)
        }
    }

    func testExplicitReturnToReadOnlyStageIsNoReturnTarget() throws {
        let yaml = """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: dev }
          - { id: dev, kind: agent, agent: { model: m1 }, on_success: review }
          - { id: review, kind: agent, agent: { model: m1, permissions: read-only }, on_success: test }
          - { id: test, kind: agent, agent: { model: m1 }, returns_to: [{ stage: review, limit: 1 }, { stage: dev, limit: 2 }], on_success: check }
          - { id: check, kind: gate, gates: [make check], on_fail: { stage: review }, on_success: merge }
          - { id: merge, kind: merge, on_conflict: { stage: review }, on_success: done }
          - { id: done, kind: terminal }
        """
        let v = PipelineValidator.validate(yaml: yaml)
        let expected: [(String, StageID)] = [("stages[3].returns_to[0].stage", "test"), ("stages[4].on_fail.stage", "check"),
                                             ("stages[5].on_conflict.stage", "merge")]
        for (path, owner) in expected {
            let issue = v.errors.first { $0.path == path }
            XCTAssertEqual(issue?.code, ValidationCode.noReturnTarget, "\(path)\n\(v.dump)")
            XCTAssertEqual(issue?.stageId, owner, path)
        }
        XCTAssertEqual(v.errors.count, 3, v.dump)
    }

    // v0.11.6 §3.1: an explicit target that is not an agent stage is `no_return_target` (not `invalid_value`);
    // `unknown_stage` stays for ids that are not in the pipeline.
    func testReturnToNonAgentStageIsNoReturnTargetAndUnknownIdIsUnknownStage() {
        let yaml = """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: dev }
          - { id: dev, kind: agent, agent: { model: m1 }, on_success: test }
          - { id: test, kind: agent, agent: { model: m1 }, returns_to: [{ stage: backlog, limit: 1 }, { stage: ghost, limit: 1 }], on_success: check }
          - { id: check, kind: gate, gates: [make], on_fail: { stage: backlog }, on_success: human }
          - { id: human, kind: human, on_success: merge }
          - { id: merge, kind: merge, on_conflict: { stage: human }, on_success: done }
          - { id: done, kind: terminal }
        """
        let v = PipelineValidator.validate(yaml: yaml)
        for (path, owner) in [("stages[2].returns_to[0].stage", "test"), ("stages[3].on_fail.stage", "check"),
                              ("stages[5].on_conflict.stage", "merge")] as [(String, StageID)] {
            let issue = v.errors.first { $0.path == path }
            XCTAssertEqual(issue?.code, ValidationCode.noReturnTarget, "\(path)\n\(v.dump)")
            XCTAssertEqual(issue?.stageId, owner, path)
        }
        XCTAssertTrue(v.has(ValidationCode.unknownStage, at: "stages[2].returns_to[1].stage"), v.dump)
        XCTAssertFalse(v.issues.contains { $0.code == ValidationCode.invalidValue }, v.dump)
        XCTAssertEqual(v.errors.count, 4, v.dump)
    }

    // v0.11.6 §3.1: the pipeline-level `no_return_target` (requestChanges default) only when requestChanges is callable.
    func testPipelineLevelNoReturnTargetOnlyWithHumanGateOrMergeStage() {
        let none = PipelineValidator.validate(yaml: """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: review }
          - { id: review, kind: agent, agent: { model: m1, permissions: read-only }, on_success: done }
          - { id: done, kind: terminal }
        """)
        XCTAssertFalse(none.issues.contains { $0.code == ValidationCode.noReturnTarget }, none.dump)
        XCTAssertTrue(none.has(ValidationCode.mergeCount, at: "stages"), none.dump)

        let human = PipelineValidator.validate(yaml: """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: review }
          - { id: review, kind: agent, agent: { model: m1, permissions: read-only }, on_success: human }
          - { id: human, kind: human, on_success: done }
          - { id: done, kind: terminal }
        """)
        let issues = human.errors.filter { $0.code == ValidationCode.noReturnTarget }
        XCTAssertEqual(issues.count, 1, human.dump)
        XCTAssertEqual(issues.first?.path, "stages")
        XCTAssertNil(issues.first?.stageId)
    }

    // MARK: Rule 7 / v0.11.5 — resolved summaries

    func testSummaryCarriesResolvedReturnsAndDefaultReturnStage() throws {
        let c = try valid(Self.pipeline())
        let summary = c.summary(projectId: "p", versionHash: "h")
        func st(_ id: StageID) throws -> StageSummary { try XCTUnwrap(summary.stages.first { $0.id == id }) }
        XCTAssertEqual(try st("check").onFail, StageReturn(stage: "dev", limit: 3))
        XCTAssertEqual(try st("check").gates, ["make check"])
        XCTAssertNil(try st("check").onConflict)
        XCTAssertEqual(try st("merge").onConflict, StageReturn(stage: "spec", limit: 2))
        XCTAssertNil(try st("merge").onFail)
        for id: StageID in ["backlog", "triage", "spec", "dev", "review", "human", "done"] {
            XCTAssertNil(try st(id).onFail, id.rawValue); XCTAssertNil(try st(id).onConflict, id.rawValue)
        }
        XCTAssertEqual(summary.defaultReturnStage, "spec")
        // Explicit values are passed through as resolved.
        let e = try valid(Self.pipeline(check: "on_fail: { stage: spec, limit: 4 },", merge: "on_conflict: { stage: dev },"))
        let es = e.summary(projectId: "p", versionHash: "h")
        XCTAssertEqual(es.stages.first { $0.id == "check" }?.onFail, StageReturn(stage: "spec", limit: 4))
        XCTAssertEqual(es.stages.first { $0.id == "merge" }?.onConflict, StageReturn(stage: "dev", limit: 2))
        // Base pipeline: same resolver as requestChanges without target.
        XCTAssertEqual(TestPipelines.base.summary(projectId: "p", versionHash: nil).defaultReturnStage, "dev")
    }

    func testDefaultReturnStageNilWhenNoWritableAgentStage() throws {
        let yaml = """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: review }
          - { id: review, kind: agent, agent: { model: m1, permissions: read-only }, on_success: merge }
          - { id: merge, kind: merge, on_success: done }
          - { id: done, kind: terminal }
        """
        let v = PipelineValidator.validate(yaml: yaml)
        let c = try XCTUnwrap(v.config)
        let summary = c.summary(projectId: "p", versionHash: nil, issues: v.issues)
        XCTAssertNil(summary.defaultReturnStage)
        XCTAssertNil(summary.stages.first { $0.id == "merge" }?.onConflict)
        XCTAssertFalse(summary.isValid)
        XCTAssertTrue(v.has(ValidationCode.noReturnTarget, at: "stages[2].on_conflict"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.noReturnTarget, at: "stages"), v.dump)
    }

    // MARK: v0.11.6 — gitPolicy in StageSummary, resolved draft

    func testSummaryGitPolicyForAgentStagesOnly() throws {
        let yaml = Self.pipeline().replacingOccurrences(of: "  - { id: dev, kind: agent, agent: { model: m1 }, on_success: review }",
            with: "  - { id: dev, kind: agent, agent: { model: m1 }, git: { extend: [rebase], when: return_reason == merge_conflict }, on_success: review }")
        let c = try valid(yaml)
        let summary = c.summary(projectId: "p", versionHash: "h")
        for st in summary.stages {
            if st.kind == .agent {
                let expected = GitPolicyResolver.resolve(project: c.git, stage: try XCTUnwrap(c.stage(st.id)))
                XCTAssertEqual(st.gitPolicy, expected, st.id.rawValue)
                XCTAssertEqual(st.gitPolicy?.readOnly, st.readOnly, st.id.rawValue)
            } else {
                XCTAssertNil(st.gitPolicy, st.id.rawValue)
            }
        }
        let dev = try XCTUnwrap(summary.stages.first { $0.id == "dev" }?.gitPolicy)
        XCTAssertEqual(dev.conditional, [ConditionalGitRule(returnReason: "merge_conflict", allowed: [GitRule("rebase", source: .stage)])])
        XCTAssertFalse(dev.allowed.contains { $0.rule == "rebase" })
        XCTAssertEqual(summary.stages.first { $0.id == "review" }?.gitPolicy?.allowed.map(\.rule), GitPolicyResolver.readCommands)
    }

    func testDraftValidationResolvedIsFilledWhenParsedEvenWithErrors() throws {
        // Valid draft: resolved == the same summary as for main (without a version hash).
        let ok = PipelineValidator.validate(yaml: Self.pipeline())
        let d = ok.draftValidation(projectId: "p", contentHash: "sha256:1")
        let resolved = try XCTUnwrap(d.resolved)
        XCTAssertEqual(resolved, try XCTUnwrap(ok.config).summary(projectId: "p", versionHash: nil, issues: ok.issues))
        XCTAssertNil(resolved.versionHash)
        XCTAssertEqual(resolved.defaultReturnStage, "spec")
        XCTAssertEqual(resolved.stages.first { $0.id == "check" }?.onFail, StageReturn(stage: "dev", limit: 3))
        XCTAssertEqual(resolved.stages.first { $0.id == "merge" }?.onConflict, StageReturn(stage: "spec", limit: 2))
        XCTAssertNotNil(resolved.stages.first { $0.id == "dev" }?.gitPolicy)
        XCTAssertEqual(d.issues, ok.issues)

        // Parses but has semantic errors: still resolved (preview), with the issues and isValid == false.
        let bad = PipelineValidator.validate(yaml: Self.pipeline(check: "on_fail: { stage: review },"))
        XCTAssertFalse(bad.isValid)
        let bd = bad.draftValidation(projectId: "p", contentHash: "sha256:2")
        let br = try XCTUnwrap(bd.resolved)
        XCTAssertFalse(br.isValid)
        XCTAssertEqual(br.issues, bad.issues)
        XCTAssertEqual(br.stages.first { $0.id == "check" }?.onFail, StageReturn(stage: "review", limit: 3))

        // Does not parse: resolved == nil.
        let broken = PipelineValidator.validate(yaml: "version: 1\nstages: [\n  - { id: x")
        XCTAssertNil(broken.config, broken.dump)
        let nd = broken.draftValidation(projectId: "p", contentHash: "sha256:3")
        XCTAssertNil(nd.resolved)
        XCTAssertEqual(nd.issues.first?.code, ValidationCode.yamlSyntax)
        let notMapping = PipelineValidator.validate(yaml: "- just\n- a list\n").draftValidation(projectId: "p", contentHash: "sha256:4")
        XCTAssertNil(notMapping.resolved)
    }

    // MARK: §3.3 — gate_failed on agent vs gate stages

    func testGateFailedOnAgentStageChargesAttemptAndRetriesInPlace() throws {
        let c = try valid(Self.pipeline())
        var h = Harness(c, stage: "dev")
        h.ok(.start(runId: "r-1"))
        h.ok(.completeStage(runId: "r-1", summary: "s"))
        h.ok(.gatesFailed(output: "1 test failed"))
        XCTAssertEqual(h.s.state, .retryWait(.gateFailed))
        XCTAssertEqual(h.s.stageId, "dev")
        XCTAssertEqual(h.s.attemptsUsed, 1)
        XCTAssertEqual(h.s.bounces, [:])
    }

    func testGateFailedOnGateStageReturnsViaDefaultsAndNeverRetriesInPlace() throws {
        let c = try valid(Self.pipeline())   // no on_fail block
        var h = Harness(c, stage: "check")
        h.ok(.start(runId: "g-1"))
        h.ok(.gatesFailed(output: "check: red"))
        XCTAssertEqual(h.s.stageId, "dev")
        XCTAssertEqual(h.s.state, .queued(nil))
        XCTAssertEqual(h.s.bounces["check_dev"], 1)
        XCTAssertEqual(h.s.attemptsUsed, 0)
        XCTAssertEqual(h.s.pendingPrompt, [.gateOutput("check: red")])
        // Default limit 3: the fourth red gate goes to the human, the task stays in the gate stage.
        var l = Harness(c, stage: "check")
        l.s.bounces = ["check_dev": 3]; l.s.totalBounces = 3
        l.ok(.start(runId: "g-4"))
        l.ok(.gatesFailed(output: "still red"))
        XCTAssertEqual(l.s.state, .waitingHuman(.bounceLimit))
        XCTAssertEqual(l.s.stageId, "check")
    }

    func testMergeConflictGoesToFirstWritableAgentStage() throws {
        let c = try valid(Self.pipeline())
        var h = Harness(c, stage: "merge")
        h.ok(.start(runId: "m"))
        h.ok(.mergeConflict(files: ["a.swift"]))
        XCTAssertEqual(h.s.stageId, "spec", "not the read-only first agent stage 'triage'")
        XCTAssertEqual(h.s.bounces["merge_conflict"], 1)
    }

    // MARK: Rule 3 — human commands

    func testRequestChangesRejectsReadOnlyTargetButMoveTaskIsAllowed() throws {
        let c = try valid(Self.pipeline())
        var h = Harness(c, stage: "human", state: .waitingHuman(.review))
        let r = h.send(.human(.requestChanges(comments: "re-review", target: "review")))
        guard case .rejected(let err) = r.outcome else { return XCTFail("read-only target must be rejected: \(r.outcome)") }
        XCTAssertEqual(err.code, CommandError.invalidStateCode)
        XCTAssertEqual(h.s.stageId, "human")
        XCTAssertEqual(h.s.state, .waitingHuman(.review))
        // Without target → the first writable agent stage (= PipelineSummary.defaultReturnStage), not `triage`.
        h.ok(.human(.requestChanges(comments: "fix it", target: nil)))
        XCTAssertEqual(h.s.stageId, c.defaultReturnStage)
        XCTAssertEqual(h.s.stageId, "spec")
        XCTAssertEqual(h.s.bounces, [:], "human returns are not counted")
        // An explicit writable target works.
        var w = Harness(c, stage: "human", state: .waitingHuman(.review))
        w.ok(.human(.requestChanges(comments: "x", target: "dev")))
        XCTAssertEqual(w.s.stageId, "dev")
        // moveTask is a move, not a return: a read-only stage is fine.
        var m = Harness(c, stage: "human", state: .waitingHuman(.review))
        m.ok(.human(.move(stage: "review")))
        XCTAssertEqual(m.s.stageId, "review")
    }

    // v0.11.6 §3.3: `reject` to a stage is a return; `reject` to cancel is always allowed.
    func testRejectToStageIsAReturn() throws {
        let c = try valid(Self.pipeline())
        for target: StageID in ["review", "triage", "check", "backlog"] {
            var h = Harness(c, stage: "human", state: .waitingHuman(.review))
            let r = h.send(.human(.reject(target: .stage(stageId: target), keepBranch: false)))
            guard case .rejected(let err) = r.outcome else { XCTFail("reject → \(target) must be rejected: \(r.outcome)"); continue }
            XCTAssertEqual(err.code, CommandError.invalidStateCode, target.rawValue)
            XCTAssertEqual(h.s.state, .waitingHuman(.review))
        }
        var w = Harness(c, stage: "human", state: .waitingHuman(.review))
        w.ok(.human(.reject(target: .stage(stageId: "dev"), keepBranch: false)))
        XCTAssertEqual(w.s.stageId, "dev")
        XCTAssertEqual(w.s.bounces, [:])
        var x = Harness(c, stage: "human", state: .waitingHuman(.review))
        x.ok(.human(.reject(target: .cancel, keepBranch: true)))
        XCTAssertEqual(x.s.state, .cancelled)

        // Even with no writable agent stage at all, reject to cancel works.
        let ro = try XCTUnwrap(PipelineValidator.validate(yaml: """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: review }
          - { id: review, kind: agent, agent: { model: m1, permissions: read-only }, on_success: human }
          - { id: human, kind: human, on_success: merge }
          - { id: merge, kind: merge, on_success: done }
          - { id: done, kind: terminal }
        """).config)
        var y = Harness(ro, stage: "human", state: .waitingHuman(.review))
        y.ok(.human(.reject(target: .cancel, keepBranch: false)))
        XCTAssertEqual(y.s.state, .cancelled)
    }

    func testRequestChangesWithoutAnyWritableStageIsInvalidState() throws {
        let yaml = """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: review }
          - { id: review, kind: agent, agent: { model: m1, permissions: read-only }, on_success: human }
          - { id: human, kind: human, on_success: merge }
          - { id: merge, kind: merge, on_success: done }
          - { id: done, kind: terminal }
        """
        let c = try XCTUnwrap(PipelineValidator.validate(yaml: yaml).config)
        var h = Harness(c, stage: "human", state: .waitingHuman(.review))
        guard case .rejected(let err) = h.send(.human(.requestChanges(comments: "x", target: nil))).outcome else { return XCTFail() }
        XCTAssertEqual(err.code, CommandError.invalidStateCode)
    }

    // MARK: stageId on stage-level issues (v0.11.2 §3.1)

    func testStageLevelIssuesCarryStageId() throws {
        let yaml = """
        version: 1
        board: { max_waiting_human: 0 }
        stages:
          - { id: backlog, kind: queue, on_success: dev, gates: [x] }
          - { id: dev, kind: agent, agent: { model: auto, harness: claude-code }, wip: 99, priority: [nope], bogus: 1, on_success: gate }
          - { id: gate, kind: gate, on_success: merge, retry: { max_attempts: 0 } }
          - { id: merge, kind: merge, wip: 2, on_success: done }
          - { id: done, kind: terminal, on_success: dev }
        """
        let v = PipelineValidator.validate(yaml: yaml)
        let ids: [StageID] = ["backlog", "dev", "gate", "merge", "done"]
        let rx = try NSRegularExpression(pattern: #"^stages\[(\d+)\]"#)
        var stageLevel = 0
        for issue in v.issues {
            let ns = issue.path as NSString
            if let m = rx.firstMatch(in: issue.path, range: NSRange(location: 0, length: ns.length)) {
                stageLevel += 1
                XCTAssertEqual(issue.stageId, ids[Int(ns.substring(with: m.range(at: 1)))!], "\(issue.path) \(issue.code)")
            } else {
                XCTAssertNil(issue.stageId, "\(issue.path) \(issue.code)")
            }
        }
        XCTAssertGreaterThanOrEqual(stageLevel, 8, v.dump)
        // Parser-level (unknown key warning, invalid priority) and validator-level issues alike.
        XCTAssertTrue(v.issues.contains { $0.code == ValidationCode.unknownKey && $0.stageId == "dev" }, v.dump)
        XCTAssertTrue(v.issues.contains { $0.code == ValidationCode.invalidValue && $0.path == "stages[1].priority[0]" && $0.stageId == "dev" }, v.dump)
        XCTAssertTrue(v.issues.contains { $0.path == "board.max_waiting_human" && $0.stageId == nil }, v.dump)
    }
}
