import XCTest
import KabanProtocol
@testable import KabanKit

/// Small harness: applies events and keeps the last result.
struct Harness {
    var s: TaskMachineState
    let p: PipelineConfig
    var last: TransitionResult?

    init(_ p: PipelineConfig, stage: StageID, state: TaskState = .queued(nil)) {
        self.p = p
        s = TaskMachineState(taskId: "t-1", stageId: stage, state: state)
    }

    @discardableResult
    mutating func send(_ e: TaskEvent, file: StaticString = #filePath, line: UInt = #line) -> TransitionResult {
        let r = TaskMachine.transition(s, e, pipeline: p)
        s = r.state
        last = r
        return r
    }

    @discardableResult
    mutating func ok(_ e: TaskEvent, file: StaticString = #filePath, line: UInt = #line) -> [TaskEffect] {
        let r = send(e)
        XCTAssertEqual(r.outcome, .applied, "\(e)", file: file, line: line)
        return r.effects
    }

    var attempt: Int { s.displayAttempt(p.stage(s.stageId)!) }

    /// Agent run that completes and passes gates + clean result check.
    mutating func passStage(_ run: RunID) {
        ok(.start(runId: run))
        ok(.completeStage(runId: run, summary: "done \(run)"))
        ok(.gatesPassed)
        ok(.resultChecked(.clean))
    }
}

extension Array where Element == TaskEffect {
    var startedRuns: [AgentRunRequest] { compactMap { if case .startAgentRun(let r) = $0 { return r }; return nil } }
    var accepted: [SuspiciousFile]? { for e in self { if case .acceptSuspiciousFiles(let f) = e { return f } }; return nil }
    var retryPauses: [Int] { compactMap { if case .scheduleRetry(let s, _) = $0 { return s }; return nil } }
    var transitions: [TaskTransition] { compactMap { if case .recordTransition(let t) = $0 { return t }; return nil } }
}

final class TaskMachineTests: XCTestCase {
    let base = TestPipelines.base

    func testHappyPathToDone() {
        var h = Harness(base, stage: "backlog")
        h.ok(.start(runId: "intake"))
        XCTAssertEqual(h.s.stageId, "dev")
        XCTAssertEqual(h.s.state, .queued(nil))

        let e1 = h.ok(.start(runId: "r-1"))
        XCTAssertEqual(h.s.state, .running)
        XCTAssertEqual(h.s.runsSinceHuman, 1)
        XCTAssertEqual(e1.startedRuns.first?.model, "composer-2")
        XCTAssertEqual(e1.startedRuns.first?.attempt, 1)
        let e2 = h.ok(.completeStage(runId: "r-1", summary: "impl"))
        XCTAssertEqual(h.s.state, .gating)
        XCTAssertTrue(e2.contains(.runGates(stageId: "dev", commands: [])))
        XCTAssertEqual(e2.transitions.first?.by, .agent)
        let e3 = h.ok(.gatesPassed)
        XCTAssertEqual(e3, [.runResultCheck(stageId: "dev")])
        let e4 = h.ok(.resultChecked(.clean))
        XCTAssertTrue(e4.contains(.commitStage(.safety)))
        XCTAssertEqual(h.s.stageId, "test")
        XCTAssertEqual(h.s.state, .queued(nil))
        XCTAssertEqual(h.attempt, 1)

        h.passStage("r-2")
        h.passStage("r-3")
        XCTAssertEqual(h.s.stageId, "human_review")
        h.ok(.start(runId: "slot"))
        XCTAssertEqual(h.s.state, .waitingHuman(.review))
        XCTAssertFalse(h.s.state.countsTowardMaxWaitingHuman)
        h.ok(.human(.approve))
        XCTAssertEqual(h.s.stageId, "merge")
        let m1 = h.ok(.start(runId: "merge"))
        XCTAssertEqual(m1.last, .startMerge(stageId: "merge", gates: []))
        h.ok(.gatesPassed)
        let m2 = h.ok(.resultChecked(.clean))
        XCTAssertEqual(m2.last, .fastForwardMerge)
        h.ok(.mainDirty)
        XCTAssertEqual(h.s.state, .blocked(.mainDirty))
        XCTAssertEqual(h.ok(.mainCleaned).last, .fastForwardMerge)
        let done = h.ok(.merged)
        XCTAssertEqual(h.s.state, .done)
        XCTAssertEqual(h.s.stageId, "done")
        XCTAssertTrue(done.contains(.expireGitGrants(.taskDone)))
        XCTAssertTrue(done.contains(.cleanupClone(keepBranch: false)))
        // Final state is absorbing.
        XCTAssertEqual(h.send(.human(.move(stage: "dev"))).outcome, .rejected(CommandError(code: CommandError.invalidStateCode, message: "Task is done; no further transitions")))
        if case .ignored = h.send(.start(runId: "x")).outcome {} else { XCTFail() }
    }

    func testRetriesWithBackoffThenExhausted_RETRY01() {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        let c = h.ok(.runEnded(runId: "r-1", .crash))
        XCTAssertEqual(h.s.state, .retryWait(.crash))
        XCTAssertEqual(h.attempt, 2)
        XCTAssertEqual(c.retryPauses, [30])
        XCTAssertTrue(c.contains(.saveWipAndRollback("r-1")))
        h.ok(.start(runId: "r-2"))
        XCTAssertEqual(h.s.runsSinceHuman, 2)
        let st = h.ok(.runEnded(runId: "r-2", .stallTimeout))
        XCTAssertEqual(st.retryPauses, [120])
        XCTAssertTrue(st.contains(.killRun("r-2")))
        XCTAssertEqual(h.attempt, 3)
        h.ok(.start(runId: "r-3"))
        h.ok(.completeStage(runId: "r-3", summary: "s"))
        let g = h.ok(.gatesFailed(output: "1 test failed"))
        XCTAssertEqual(h.s.state, .waitingHuman(.retriesExhausted))
        XCTAssertEqual(h.attempt, 3)
        XCTAssertTrue(g.contains(.notifyHuman(.retriesExhausted)))
        // retryStage grants one more attempt when exhausted and resets the run counter.
        h.ok(.human(.retryStage(grantAttempts: nil)))
        XCTAssertEqual(h.s.runsSinceHuman, 0)
        XCTAssertEqual(h.s.attemptLimit(base.stage("dev")!), 4)
        let r4 = h.ok(.start(runId: "r-4"))
        XCTAssertEqual(r4.startedRuns.first?.attempt, 4)
        XCTAssertEqual(r4.startedRuns.first?.continueInClone, true)   // gate output is still pending
    }

    func testGateFailedContinuesInClone_RETRY03() {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        h.ok(.completeStage(runId: "r-1", summary: "s"))
        let g = h.ok(.gatesFailed(output: "boom"))
        XCTAssertFalse(g.contains { if case .saveWipAndRollback = $0 { return true }; return false })
        let r = h.ok(.start(runId: "r-2")).startedRuns[0]
        XCTAssertTrue(r.continueInClone)
        XCTAssertEqual(r.prompt, [.gateOutput("boom")])
        h.ok(.runEnded(runId: "r-2", .noFinalCall))
        let r3 = h.ok(.start(runId: "r-3")).startedRuns[0]
        XCTAssertEqual(r3.prompt, [.finishReminder])
        XCTAssertTrue(r3.continueInClone)
    }

    func testNonChargingRunsKeepCounters() {
        let cases: [(RunFailure, TaskState)] = [
            (.rateLimit, .retryWait(.rateLimit)),
            (.runnerAuth, .retryWait(.runnerAuth)),
            (.silentExit, .retryWait(.silentExit)),
            (.usageExhausted(.om), .queued(.quotaOm)),
            (.usageExhausted(nil), .queued(nil)),
            (.modelUnavailable, .queued(.modelFlag)),
        ]
        for (failure, expected) in cases {
            var h = Harness(base, stage: "dev")
            h.ok(.start(runId: "r-1"))
            XCTAssertEqual(h.s.runsSinceHuman, 1)
            let e = h.ok(.runEnded(runId: "r-1", failure))
            XCTAssertEqual(h.s.state, expected, "\(failure)")
            XCTAssertEqual(h.s.attemptsUsed, 0, "\(failure)")
            XCTAssertEqual(h.s.runsSinceHuman, 0, "\(failure)")
            XCTAssertEqual(h.attempt, 1)
            XCTAssertTrue(e.retryPauses.isEmpty)
        }
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        let restart = h.ok(.daemonRestarted)
        XCTAssertEqual(h.s.state, .retryWait(.daemonRestart))
        XCTAssertEqual(h.s.runsSinceHuman, 0)
        XCTAssertTrue(restart.contains(.saveWipAndRollback("r-1")))
    }

    func testModelSubstitution_SUBST01() {
        let opus = PipelineValidator.validate(yaml: TestPipelines.baseYAML.replacingOccurrences(
            of: "agent: { model: composer-2 }\n    on_success: test", with: "agent: { model: claude-opus }\n    on_success: test")).config!
        var h = Harness(opus, stage: "dev")
        h.ok(.start(runId: "r-1"))
        let e = h.ok(.modelMismatch(runId: "r-1", requested: "claude-opus", actual: "claude-sonnet", fallback: nil))
        XCTAssertEqual(h.s.state, .waitingHuman(.modelSubstituted))
        XCTAssertEqual(h.s.runsSinceHuman, 0)
        XCTAssertEqual(h.s.attemptsUsed, 0)
        XCTAssertTrue(e.contains(.killRun("r-1")))
        XCTAssertTrue(e.contains(.raiseModelFlag(ModelFlagRequest(modelId: "claude-opus", reason: .substituted, requested: "claude-opus",
                                                                  actual: "claude-sonnet", fallbackModel: nil))))
        // The killed run's late exit is stale.
        if case .ignored = h.send(.runEnded(runId: "r-1", .crash)).outcome {} else { XCTFail() }
    }

    func testSilentExitProbe() {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        XCTAssertTrue(h.ok(.runEnded(runId: "r-1", .silentExit)).contains(.requestModelProbe("composer-2")))
        h.ok(.probeFinished(.clean))
        XCTAssertEqual(h.s.state, .retryWait(.crash))
        XCTAssertEqual(h.s.attemptsUsed, 1)
        XCTAssertEqual(h.s.runsSinceHuman, 1)
        XCTAssertEqual(h.last?.effects.retryPauses, [30])

        var q = Harness(base, stage: "dev")
        q.ok(.start(runId: "r-1"))
        q.ok(.runEnded(runId: "r-1", .silentExit))
        q.ok(.probeFinished(.usageExhausted(.cm)))
        XCTAssertEqual(q.s.state, .queued(.quotaCm))
        XCTAssertEqual(q.s.attemptsUsed, 0)
        if case .ignored = q.send(.probeFinished(.clean)).outcome {} else { XCTFail("second probe result must be ignored") }
    }

    func testRetryBlockedByQuotaReleasesSlot() {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        h.ok(.completeStage(runId: "r-1", summary: "s"))
        h.ok(.gatesFailed(output: "red"))
        XCTAssertTrue(h.s.state.status.occupiesWIP)
        h.ok(.startBlocked(.quota(.om)))
        XCTAssertEqual(h.s.state, .queued(.quotaOm))
        XCTAssertFalse(h.s.state.status.occupiesWIP)
        XCTAssertEqual(h.s.attemptsUsed, 1)
        let r = h.ok(.start(runId: "r-2")).startedRuns[0]
        XCTAssertEqual(r.attempt, 2)
        XCTAssertEqual(r.prompt, [.gateOutput("red")])
        // wip_full never applies to retry_wait (it already holds the slot)
        var w = Harness(base, stage: "dev", state: .retryWait(.crash))
        if case .ignored = w.send(.startBlocked(.wipFull)).outcome {} else { XCTFail() }
    }

    func testRunLimit_RUNLIMIT01_02() {
        var h = Harness(base, stage: "dev")
        h.s.runsSinceHuman = 12
        let e = h.ok(.start(runId: "r-13"))
        XCTAssertEqual(h.s.state, .waitingHuman(.runLimit))
        XCTAssertTrue(e.startedRuns.isEmpty)
        h.ok(.human(.retryStage(grantAttempts: nil)))
        XCTAssertEqual(h.s.state, .queued(nil))
        XCTAssertEqual(h.s.runsSinceHuman, 0)
        XCTAssertEqual(h.attempt, 1)
        h.ok(.start(runId: "r-1"))
        XCTAssertEqual(h.s.runsSinceHuman, 1)

        // A charged failure of the 12th run goes straight to run_limit instead of waiting for a retry.
        var g = Harness(base, stage: "test")
        g.s.runsSinceHuman = 11
        g.ok(.start(runId: "r-12"))
        g.ok(.runEnded(runId: "r-12", .crash))
        XCTAssertEqual(g.s.state, .waitingHuman(.runLimit))
    }

    func testReturnsAndLimits_BOUNCE01_02() {
        var h = Harness(base, stage: "test")
        h.ok(.start(runId: "r-1"))
        let e = h.ok(.returnToStage(runId: "r-1", target: "dev", issues: ["no tests"]))
        XCTAssertEqual(h.s.stageId, "dev")
        XCTAssertEqual(h.s.bounces, ["test_dev": 1])
        XCTAssertEqual(h.s.priority, .returned)
        XCTAssertEqual(e.transitions.first?.note, "test_dev")
        XCTAssertEqual(h.s.pendingPrompt, [.returnIssues(from: "test", issues: ["no tests"])])
        // Not an allowed target → MCP error, nothing changes.
        h.passStage("r-2")
        h.ok(.start(runId: "r-3"))
        guard case .rejected = h.send(.returnToStage(runId: "r-3", target: "backlog", issues: [])).outcome else { return XCTFail() }
        XCTAssertEqual(h.s.state, .running)

        var b1 = Harness(base, stage: "test", state: .running)
        b1.s.currentRunId = "r-1"; b1.s.bounces = ["test_dev": 3]; b1.s.totalBounces = 3
        b1.ok(.returnToStage(runId: "r-1", target: "dev", issues: []))
        XCTAssertEqual(b1.s.state, .waitingHuman(.bounceLimit))
        XCTAssertEqual(b1.s.stageId, "test")

        var b2 = Harness(base, stage: "ai_review", state: .running)
        b2.s.currentRunId = "r-1"; b2.s.bounces = ["test_dev": 3, "ai_review_dev": 1]; b2.s.totalBounces = 5
        b2.ok(.returnToStage(runId: "r-1", target: "dev", issues: []))
        XCTAssertEqual(b2.s.state, .waitingHuman(.bounceLimit))
    }

    func testMergeConflictPathAndLimit() {
        var h = Harness(base, stage: "merge")
        h.ok(.start(runId: "m"))
        h.ok(.mergeConflict(files: ["a.swift"]))
        XCTAssertEqual(h.s.stageId, "dev")
        XCTAssertEqual(h.s.returnReason, .mergeConflict)
        XCTAssertEqual(h.s.bounces["merge_conflict"], 1)
        let policy = GitPolicyResolver.resolve(project: base.git, stage: base.stage("dev")!, returnReason: h.s.returnReason)
        XCTAssertEqual(policy.preset, .standard)
        let r = h.ok(.start(runId: "r-1")).startedRuns[0]
        XCTAssertEqual(r.prompt, [.mergeConflict(files: ["a.swift"])])
        XCTAssertEqual(r.returnReason, .mergeConflict)

        // Red gates after a clean rebase take the same path; third time → conflict_limit.
        var m = Harness(base, stage: "merge")
        m.s.bounces = ["merge_conflict": 2]; m.s.totalBounces = 2
        m.ok(.start(runId: "m"))
        m.ok(.gatesFailed(output: "red after rebase"))
        XCTAssertEqual(m.s.state, .waitingHuman(.conflictLimit))
        XCTAssertEqual(m.s.stageId, "merge")
    }

    func testStaleAndIllegalAgentCalls() {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        if case .rejected = h.send(.completeStage(runId: "r-x", summary: "")).outcome {} else { XCTFail() }
        h.ok(.completeStage(runId: "r-1", summary: "s"))
        if case .ignored = h.send(.completeStage(runId: "r-1", summary: "s")).outcome {} else { XCTFail("repeat is idempotent") }
        if case .ignored = h.send(.runEnded(runId: "r-1", .crash)).outcome {} else { XCTFail() }
        if case .rejected = h.send(.human(.approve)).outcome {} else { XCTFail() }
        XCTAssertEqual(h.s.state, .gating)
    }

    func testQuestionAnswerResumesSession_WIP02() {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        let q = h.ok(.requestHuman(runId: "r-1", question: "Date format?"))
        XCTAssertEqual(h.s.state, .waitingHuman(.question))
        XCTAssertFalse(h.s.state.status.occupiesWIP)
        XCTAssertTrue(q.contains(.recordHumanRequest(question: "Date format?", runId: "r-1")))
        XCTAssertEqual(h.s.runsSinceHuman, 1)
        h.ok(.human(.answer(text: "ISO 8601", requestId: nil)))
        XCTAssertEqual(h.s.state, .queued(nil))
        XCTAssertEqual(h.s.priority, .answered)
        XCTAssertEqual(h.s.runsSinceHuman, 0)
        let r = h.ok(.start(runId: "r-2")).startedRuns[0]
        XCTAssertTrue(r.resumeSession)
        XCTAssertEqual(r.prompt, [.humanAnswer("ISO 8601")])
        XCTAssertEqual(r.attempt, 1, "a question does not burn an attempt")
    }

    func testPauseResumeCancel_PAUSE01_CANCEL01() {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        XCTAssertTrue(h.ok(.human(.pause)).contains(.killRun("r-1")))
        XCTAssertEqual(h.s.state, .paused)
        if case .ignored = h.send(.start(runId: "r-2")).outcome {} else { XCTFail("paused tasks do not start") }
        h.ok(.human(.resume))
        XCTAssertEqual(h.s.state, .queued(nil))
        XCTAssertEqual(h.attempt, 1)
        XCTAssertEqual(h.s.runsSinceHuman, 0)

        var c = Harness(base, stage: "dev")
        c.ok(.start(runId: "r-1"))
        let e = c.ok(.human(.cancel(keepBranch: true)))
        XCTAssertEqual(c.s.state, .cancelled)
        XCTAssertTrue(e.contains(.killRun("r-1")))
        XCTAssertTrue(e.contains(.cleanupClone(keepBranch: true)))
        XCTAssertTrue(e.contains(.expireGitGrants(.taskCancelled)))
    }

    func testIncidentResolvedByHuman() {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        let e = h.ok(.resultChecked(.incident(.refsMoved)))   // periodic check during the run
        XCTAssertTrue(e.contains(.killRun("r-1")))
        XCTAssertTrue(e.contains(.openIncident(.refsMoved, runId: "r-1")))
        XCTAssertEqual(h.s.state, .waitingHuman(.incident))
        let m = h.ok(.human(.move(stage: "dev")))
        XCTAssertTrue(m.contains(.resolveIncident))
        XCTAssertNil(h.s.openIncident)
    }

    func testReadOnlyViolation() {
        var h = Harness(base, stage: "ai_review")
        h.ok(.start(runId: "r-1"))
        h.ok(.completeStage(runId: "r-1", summary: "lgtm"))
        h.ok(.gatesPassed)
        let e = h.ok(.resultChecked(.readOnlyChanges))
        XCTAssertTrue(e.contains(.saveWipAndRollback("r-1")))
        XCTAssertEqual(h.s.state, .retryWait(.gateFailed))
        h.ok(.start(runId: "r-2"))
        h.ok(.completeStage(runId: "r-2", summary: "lgtm"))
        h.ok(.gatesPassed)
        h.ok(.resultChecked(.readOnlyChanges))
        XCTAssertEqual(h.s.state, .waitingHuman(.invalidResult))
    }

    func testStrictPresetCommitsWithSummary() {
        let p = TestPipelines.smallLimits
        var h = Harness(p, stage: "dev")
        h.ok(.start(runId: "r-1"))
        h.ok(.completeStage(runId: "r-1", summary: "Add login form"))
        h.ok(.gatesPassed)
        XCTAssertTrue(h.ok(.resultChecked(.clean)).contains(.commitStage(.daemonSingle(summary: "Add login form"))))
        // Gate stage with on_fail returns to dev with the gate output.
        let g = h.ok(.start(runId: "gate"))
        XCTAssertEqual(g.last, .runGates(stageId: "lint", commands: ["make lint"]))
        h.ok(.gatesFailed(output: "lint: 3 errors"))
        XCTAssertEqual(h.s.stageId, "dev")
        XCTAssertEqual(h.s.bounces["lint_dev"], 1)
        XCTAssertEqual(h.s.pendingPrompt, [.gateOutput("lint: 3 errors")])
    }

    func testDaemonRestartDuringGatingRerunsPhase() {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        h.ok(.completeStage(runId: "r-1", summary: "s"))
        XCTAssertEqual(h.ok(.daemonRestarted), [.runGates(stageId: "dev", commands: [])])
        h.ok(.gatesPassed)
        XCTAssertEqual(h.ok(.daemonRestarted), [.runResultCheck(stageId: "dev")])
        XCTAssertEqual(h.s.state, .gating)
    }

    func testRequestChangesAndRejectFromReview() {
        var h = Harness(base, stage: "human_review", state: .waitingHuman(.review))
        if case .rejected = h.send(.human(.requestChanges(comments: "x", target: "merge"))).outcome {} else { XCTFail("forward target") }
        if case .rejected = h.send(.human(.answer(text: "x", requestId: nil))).outcome {} else { XCTFail("no agent in human stage") }
        if case .rejected = h.send(.human(.retryStage(grantAttempts: 1))).outcome {} else { XCTFail("no retry of review") }
        h.ok(.human(.requestChanges(comments: "rename it", target: nil)))
        XCTAssertEqual(h.s.stageId, "dev")
        XCTAssertEqual(h.s.bounces, [:], "human returns are not counted")
        XCTAssertEqual(h.s.pendingPrompt, [.humanComments("rename it")])

        var r = Harness(base, stage: "human_review", state: .waitingHuman(.review))
        r.ok(.human(.reject(target: .stage(stageId: "test"), keepBranch: false)))
        XCTAssertEqual(r.s.stageId, "test")
        var c = Harness(base, stage: "human_review", state: .waitingHuman(.review))
        c.ok(.human(.reject(target: .cancel, keepBranch: true)))
        XCTAssertEqual(c.s.state, .cancelled)
    }

    func testStateCodableAndHumanActionFromCommand() throws {
        var h = Harness(base, stage: "dev")
        h.ok(.start(runId: "r-1"))
        h.ok(.completeStage(runId: "r-1", summary: "s"))
        h.ok(.gatesFailed(output: "x"))
        let data = try JSONEncoder().encode(h.s)
        XCTAssertEqual(try JSONDecoder().decode(TaskMachineState.self, from: data), h.s)
        XCTAssertEqual(HumanAction(command: .retryStage(taskId: "t", grantAttempts: 2)), .retryStage(grantAttempts: 2))
        XCTAssertEqual(HumanAction(command: .acceptSuspiciousFiles(taskId: "t", files: [])), .acceptSuspiciousFiles([]))
        XCTAssertNil(HumanAction(command: .pauseAll))
        var card = TaskCard(id: "t-1", projectId: "p", title: "x", stageId: "backlog", state: .queued(nil), updatedAt: Date(timeIntervalSince1970: 0))
        h.s.apply(to: &card, stage: base.stage(h.s.stageId))
        XCTAssertEqual(card.attempt, 2)
        XCTAssertEqual(card.maxAttempts, 3)
        XCTAssertEqual(card.state, .retryWait(.gateFailed))
    }
}
