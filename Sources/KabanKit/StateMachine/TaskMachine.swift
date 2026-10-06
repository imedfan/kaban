import Foundation
import KabanProtocol

/// Pure, deterministic task state machine (architecture §3.2–§3.3, decisions log «Ретраи и лимиты запусков»).
///
/// `transition(state, event, pipeline)` never performs I/O and never reads the clock: the same inputs always give
/// the same `(state, effects)`. Illegal commands come back as `.rejected` with the state unchanged; events of
/// stale runs come back as `.ignored`. Every status/stage change emits `.recordTransition` first.
///
/// WIP is not counted here: `TaskStatus.occupiesWIP` (running, gating, retry_wait) is the source of truth and the
/// scheduler (`KabanDaemonCore`) only issues `.start` when a slot is free; a task waiting for quota/model flag goes to
/// `queued(reason)` and holds no slot.
public enum TaskMachine {
    public static func transition(_ state: TaskMachineState, _ event: TaskEvent, pipeline: PipelineConfig) -> TransitionResult {
        var m = Machine(s: state, pipeline: pipeline, event: event)
        m.apply()
        switch m.outcome {
        case .applied:
            return TransitionResult(state: m.s, effects: m.effects, outcome: .applied)
        default:
            return TransitionResult(state: state, effects: [], outcome: m.outcome)
        }
    }

    public static let actorForEvent: @Sendable (TaskEvent) -> Actor = { event in
        switch event {
        case .start, .startBlocked: .scheduler
        case .completeStage, .returnToStage, .requestHuman: .agent
        case .human: .human
        default: .daemon
        }
    }
}

private struct Machine {
    var s: TaskMachineState
    let pipeline: PipelineConfig
    let event: TaskEvent
    var effects: [TaskEffect] = []
    var outcome: TransitionOutcome = .applied

    let original: TaskMachineState

    init(s: TaskMachineState, pipeline: PipelineConfig, event: TaskEvent) {
        self.s = s; self.pipeline = pipeline; self.event = event; self.original = s
    }

    var stage: StageConfig? { pipeline.stage(s.stageId) }
    var actor: Actor { TaskMachine.actorForEvent(event) }

    // MARK: Outcome helpers

    mutating func reject(_ message: String, code: String = CommandError.invalidStateCode) {
        outcome = .rejected(CommandError(code: code, message: message))
    }
    mutating func ignore(_ why: String) { outcome = .ignored(why) }

    /// Sets the new state and journals the transition (also when only the stage changes).
    mutating func set(_ new: TaskState, note: String? = nil, runId: RunID? = nil) {
        let fromStage = original.stageId
        let from = original.state
        s.state = new
        if new != .running { s.currentRunId = nil }
        if case .gating = new {} else if case .blocked = new {} else { s.gatingPhase = nil }
        effects.removeAll { if case .recordTransition = $0 { return true }; return false }
        if from != new || fromStage != s.stageId {
            effects.insert(.recordTransition(TaskTransition(taskId: s.taskId, fromStage: fromStage, toStage: s.stageId, from: from,
                                                            to: new, by: actor, runId: runId ?? original.currentRunId ?? s.currentRunId,
                                                            note: note)), at: 0)
        }
    }

    // MARK: Dispatch

    mutating func apply() {
        if s.state == .done || s.state == .cancelled {
            if case .human = event { reject("Task is \(s.state.status.rawValue); no further transitions") } else { ignore("task is final") }
            return
        }
        guard let stage else {
            // Stage vanished from the pipeline: only moving or cancelling the task makes sense.
            switch event {
            case .human(.move(let target)): humanMove(target)
            case .human(.cancel(let keep)): cancel(keepBranch: keep)
            case .human: reject("Stage '\(s.stageId)' is not in the current pipeline; move or cancel the task", code: CommandError.notFoundCode)
            default: ignore("stage missing from pipeline")
            }
            return
        }
        switch event {
        case .start(let runId): start(stage, runId: runId)
        case .startBlocked(let block): startBlocked(block)
        case .completeStage(let runId, let summary): completeStage(stage, runId: runId, summary: summary)
        case .returnToStage(let runId, let target, let issues): agentReturn(stage, runId: runId, target: target, issues: issues)
        case .requestHuman(let runId, let question): requestHuman(runId: runId, question: question)
        case .runEnded(let runId, let failure): runEnded(stage, runId: runId, failure: failure)
        case .modelMismatch(let runId, let requested, let actual, let fallback):
            modelMismatch(stage, runId: runId, requested: requested, actual: actual, fallback: fallback)
        case .gitDenialLimit(let runId): gitDenialLimit(runId: runId)
        case .daemonRestarted: daemonRestarted(stage)
        case .probeFinished(let outcome): probeFinished(stage, outcome)
        case .gatesPassed: gatesPassed(stage)
        case .gatesFailed(let output): gatesFailed(stage, output: output)
        case .resultChecked(let check): resultChecked(stage, check)
        case .mergeConflict(let files): mergeConflictOrRedGates(stage, prompt: .mergeConflict(files: files), phase: .rebase)
        case .mainDirty: mainDirty()
        case .mainCleaned: mainCleaned()
        case .mainMoved: mainMoved(stage)
        case .merged: merged(stage)
        case .human(let action): human(stage, action)
        }
    }

    // MARK: Scheduler

    mutating func start(_ stage: StageConfig, runId: RunID) {
        switch s.state {
        case .queued, .retryWait: break
        default: return ignore("start only from queued or retry_wait")
        }
        switch stage.kind {
        case .queue:
            enter(stage.onSuccess, priority: nil, prompt: [], returnReason: nil, note: "intake")
        case .agent:
            guard let model = stage.agent?.model, PipelineValidator.hasExplicitModel(model) else {
                return ignore("stage has no explicit model (pipeline_invalid)")
            }
            if s.runsSinceHuman >= pipeline.board.maxRunsPerTask {
                waitHuman(.runLimit, note: "max_runs_per_task \(pipeline.board.maxRunsPerTask) reached")
                return
            }
            if s.attemptsExhausted(stage) {
                waitHuman(.retriesExhausted)
                return
            }
            let continueInClone = s.pendingPrompt.contains { if case .gateOutput = $0 { return true }; return $0 == .finishReminder }
            let request = AgentRunRequest(runId: runId, stageId: stage.id, model: model, attempt: s.attemptsUsed + 1,
                                          maxAttempts: s.attemptLimit(stage), readOnly: stage.isReadOnly,
                                          continueInClone: continueInClone, resumeSession: s.resumeSession,
                                          prompt: s.pendingPrompt, returnReason: s.returnReason)
            s.currentRunId = runId
            s.lastRunId = runId
            s.runsSinceHuman += 1   // counted at start; refunded if the run turns out not to charge
            s.pendingPrompt = []
            s.resumeSession = false
            s.silentExitPending = false
            set(.running, runId: runId)
            effects.append(.startAgentRun(request))
        case .gate:
            s.gatingPhase = .gates
            set(.gating)
            effects.append(.runGates(stageId: stage.id, commands: stage.gates))
        case .merge:
            s.gatingPhase = .rebase
            set(.gating)
            effects.append(.startMerge(stageId: stage.id, gates: stage.gates))
        case .human:
            waitHuman(.review)
        case .terminal:
            s.gatingPhase = nil
            set(.done)
        }
    }

    mutating func startBlocked(_ block: StartBlock) {
        let reason: QueuedReason
        switch block {
        case .wipFull:
            guard case .queued = s.state else { return ignore("wip_full only labels queued tasks") }
            reason = .wipFull
        case .quota(let pool):
            reason = pool == .cm ? .quotaCm : .quotaOm
        case .modelFlag:
            reason = .modelFlag
        }
        switch s.state {
        case .queued, .retryWait:
            // A retry blocked by quota/model flag releases its WIP slot and keeps its pending context; no attempt charged.
            set(.queued(reason))
        default:
            ignore("start blocks apply only to queued or retry_wait")
        }
    }

    // MARK: Agent MCP calls

    /// Checks that an MCP call belongs to the live run. Repeats from the same (finished) run are idempotent.
    mutating func checkRun(_ runId: RunID, call: String) -> Bool {
        if s.state == .running && s.currentRunId == runId { return true }
        if s.lastRunId == runId { ignore("\(call): repeated call from a finished run (idempotent)"); return false }
        reject("\(call): run \(runId) is not the active run of this task")
        return false
    }

    mutating func completeStage(_ stage: StageConfig, runId: RunID, summary: String) {
        guard checkRun(runId, call: "complete_stage") else { return }
        s.lastSummary = summary
        s.gatingPhase = .gates
        set(.gating, runId: runId)
        effects.append(.runGates(stageId: stage.id, commands: stage.gates))
    }

    mutating func agentReturn(_ stage: StageConfig, runId: RunID, target: StageID, issues: [String]) {
        guard s.state == .running && s.currentRunId == runId else { _ = checkRun(runId, call: "return_to_stage"); return }
        guard let limit = stage.returnLimit(to: target) else {
            return reject("return_to_stage: '\(stage.id)' cannot return to '\(target)'; allowed: \(stage.returnsTo.map(\.stage.rawValue).joined(separator: ", "))")
        }
        bounce(key: TaskMachineState.bounceKey(from: stage.id, to: target), limit: limit, limitReason: .bounceLimit, target: target,
               prompt: [.returnIssues(from: stage.id, issues: issues)], returnReason: .returned, runId: runId)
    }

    mutating func requestHuman(runId: RunID, question: String) {
        guard checkRun(runId, call: "request_human") else { return }
        s.resumeSession = true
        effects.append(.recordHumanRequest(question: question, runId: runId))
        waitHuman(.question, runId: runId)
    }

    // MARK: Run lifecycle

    mutating func runEnded(_ stage: StageConfig, runId: RunID, failure: RunFailure) {
        guard s.state == .running, s.currentRunId == runId else { return ignore("runEnded for a run that is not active") }
        let model = stage.agent?.model
        switch failure {
        case .crash, .stallTimeout, .wallTimeout:
            if failure != .crash { effects.append(.killRun(runId)) }
            effects.append(.saveWipAndRollback(runId))
            chargeAttempt(stage, reason: failure == .crash ? .crash : failure == .stallTimeout ? .stallTimeout : .wallTimeout)
        case .noFinalCall:
            s.pendingPrompt.append(.finishReminder)
            chargeAttempt(stage, reason: .noFinalCall)
        case .rateLimit:
            refundRun()
            set(.retryWait(.rateLimit))
            effects.append(.raiseRateLimit)
        case .runnerAuth:
            refundRun()
            set(.retryWait(.runnerAuth))
            effects.append(.raiseRunnerUnavailable(.runnerAuth))
        case .silentExit:
            refundRun()
            s.silentExitPending = true
            set(.retryWait(.silentExit))
            if let model { effects.append(.requestModelProbe(model)) }
        case .usageExhausted(let pool):
            refundRun()
            set(.queued(pool.map { $0 == .cm ? .quotaCm : .quotaOm }))
            effects.append(.raiseUsageExhausted(pool))
        case .modelUnavailable:
            refundRun()
            set(.queued(.modelFlag))
            if let model { effects.append(.raiseModelFlag(ModelFlagRequest(modelId: model, reason: .unavailable))) }
        }
    }

    mutating func modelMismatch(_ stage: StageConfig, runId: RunID, requested: String, actual: String, fallback: String?) {
        guard s.state == .running, s.currentRunId == runId else { return ignore("model mismatch for a run that is not active") }
        effects.append(.killRun(runId))
        refundRun()
        if let model = stage.agent?.model {
            effects.append(.raiseModelFlag(ModelFlagRequest(modelId: model, reason: .substituted, requested: requested,
                                                            actual: actual, fallbackModel: fallback)))
        }
        // Result not accepted, attempt not charged, run not counted.
        waitHuman(.modelSubstituted, runId: runId)
    }

    mutating func gitDenialLimit(runId: RunID) {
        guard s.state == .running, s.currentRunId == runId else { return ignore("git denial limit for a run that is not active") }
        effects.append(.killRun(runId))
        waitHuman(.gitDenials, runId: runId)
    }

    mutating func daemonRestarted(_ stage: StageConfig) {
        switch s.state {
        case .running:
            let runId = s.currentRunId!
            effects.append(.killRun(runId))
            effects.append(.saveWipAndRollback(runId))
            refundRun()
            set(.retryWait(.daemonRestart))
            effects.append(.scheduleRetry(afterSeconds: 0, reason: .daemonRestart))
        case .gating:
            switch s.gatingPhase ?? .gates {
            case .gates: effects.append(.runGates(stageId: stage.id, commands: stage.gates))
            case .resultCheck: effects.append(.runResultCheck(stageId: stage.id))
            case .rebase: effects.append(.startMerge(stageId: stage.id, gates: stage.gates))
            case .fastForward: effects.append(.fastForwardMerge)
            }
        default:
            ignore("nothing to recover")
        }
    }

    mutating func probeFinished(_ stage: StageConfig, _ probe: ProbeOutcome) {
        guard s.state == .retryWait(.silentExit), s.silentExitPending else { return ignore("no silent exit waiting for a probe") }
        s.silentExitPending = false
        switch probe {
        case .clean:
            // Ordinary failure after all: charge the attempt and the run retroactively.
            s.runsSinceHuman = min(s.runsSinceHuman + 1, pipeline.board.maxRunsPerTask)
            chargeAttempt(stage, reason: .crash)
        case .rateLimit:
            set(.retryWait(.rateLimit))
            effects.append(.raiseRateLimit)
        case .usageExhausted(let pool):
            set(.queued(pool.map { $0 == .cm ? .quotaCm : .quotaOm }))
            effects.append(.raiseUsageExhausted(pool))
        case .modelUnavailable:
            set(.queued(.modelFlag))
            if let model = stage.agent?.model { effects.append(.raiseModelFlag(ModelFlagRequest(modelId: model, reason: .unavailable))) }
        }
    }

    /// One charged failure. Order: attempts exhausted → `retries_exhausted`; else run limit → `run_limit`;
    /// else `retry_wait(reason)` with the stage backoff.
    mutating func chargeAttempt(_ stage: StageConfig, reason: RetryWaitReason) {
        s.attemptsUsed += 1
        if s.attemptsExhausted(stage) {
            waitHuman(.retriesExhausted, note: "\(s.attemptsUsed)/\(s.attemptLimit(stage)) attempts, last: \(reason.rawValue)")
        } else if stage.kind == .agent && s.runsSinceHuman >= pipeline.board.maxRunsPerTask {
            waitHuman(.runLimit, note: "max_runs_per_task \(pipeline.board.maxRunsPerTask) reached")
        } else {
            set(.retryWait(reason))
            effects.append(.scheduleRetry(afterSeconds: stage.retry.pause(afterFailedAttempts: s.attemptsUsed), reason: reason))
        }
    }

    /// Runs that do not charge an attempt are not counted toward `max_runs_per_task` (§3.2).
    mutating func refundRun() { s.runsSinceHuman = max(0, s.runsSinceHuman - 1) }

    // MARK: Gates, result check, merge

    mutating func gatesPassed(_ stage: StageConfig) {
        guard s.state == .gating, s.gatingPhase == .gates || s.gatingPhase == .rebase else { return ignore("not running gates") }
        s.gatingPhase = .resultCheck
        effects.append(.runResultCheck(stageId: stage.id))
    }

    mutating func gatesFailed(_ stage: StageConfig, output: String) {
        guard s.state == .gating else { return ignore("not running gates") }
        if s.gatingPhase == .rebase {
            // Clean rebase but red gates: same path as a conflict (§8.5).
            return mergeConflictOrRedGates(stage, prompt: .gateOutput(output), phase: .rebase)
        }
        guard s.gatingPhase == .gates else { return ignore("not running gates") }
        switch stage.kind {
        case .agent:
            // Next attempt continues in the same clone with the gate output in the prompt (§6.1).
            s.pendingPrompt.append(.gateOutput(output))
            chargeAttempt(stage, reason: .gateFailed)
        case .gate:
            // A red gate is never retried in place (v0.11.4 §3.1); no target only happens with an invalid pipeline.
            guard let fail = stage.failReturn(in: pipeline) else { return waitHuman(.bounceLimit, note: "no return target for a red gate") }
            bounce(key: TaskMachineState.bounceKey(from: stage.id, to: fail.stage), limit: fail.limit, limitReason: .bounceLimit, target: fail.stage,
                   prompt: [.gateOutput(output)], returnReason: .returned, runId: nil)
        default:
            ignore("stage has no gates")
        }
    }

    mutating func resultChecked(_ stage: StageConfig, _ check: ResultCheck) {
        let duringRun = s.state == .running
        let duringFastForward = s.state == .gating && s.gatingPhase == .fastForward
        if case .incident = check, duringRun {
            // Periodic ref snapshots can catch a violation while the run is still alive.
        } else if duringFastForward {
            // The pre-update recheck only diverts a merge that is no longer clean. A second clean does not emit another ff.
            if case .clean = check { return ignore("already checked") }
        } else {
            guard s.state == .gating, s.gatingPhase == .resultCheck else { return ignore("no result check in progress") }
        }
        switch check {
        case .clean:
            proceedAfterCleanCheck(stage)
        case .suspiciousFiles(let files):
            if files.isEmpty { return proceedAfterCleanCheck(stage) }
            // Not a run failure: no attempt charged (§8.2). The run was already counted at complete_stage.
            s.suspiciousFiles = files
            effects.append(.reportSuspiciousFiles(files, runId: s.lastRunId))
            waitHuman(.suspiciousFiles)
        case .incident(let kind):
            if duringRun, let run = s.currentRunId { effects.append(.killRun(run)) }
            s.openIncident = kind
            effects.append(.openIncident(kind, runId: s.lastRunId))
            waitHuman(.incident)
        case .readOnlyChanges:
            if let run = s.lastRunId { effects.append(.saveWipAndRollback(run)) }
            s.invalidResultStrikes += 1
            if s.invalidResultStrikes >= 2 {
                waitHuman(.invalidResult)
            } else {
                s.pendingPrompt.append(.readOnlyViolation)
                chargeAttempt(stage, reason: .readonlyViolation)
            }
        }
    }

    /// The transition a clean result check (or accepted suspicious files) unblocks: next stage, or the ff-merge.
    mutating func proceedAfterCleanCheck(_ stage: StageConfig) {
        s.suspiciousFiles = []
        switch stage.kind {
        case .merge:
            s.gatingPhase = .fastForward
            set(.gating)
            effects.append(.fastForwardMerge)
        case .agent:
            let committer = GitPolicyResolver.resolve(project: pipeline.git, stage: stage).committer
            effects.append(.commitStage(committer == .daemonOnly ? .daemonSingle(summary: s.lastSummary ?? "kaban: \(stage.id) \(s.taskId)") : .safety))
            enter(stage.onSuccess, priority: nil, prompt: [], returnReason: nil, note: nil)
        default:
            enter(stage.onSuccess, priority: nil, prompt: [], returnReason: nil, note: nil)
        }
    }

    mutating func mergeConflictOrRedGates(_ stage: StageConfig, prompt: PromptAddition, phase: GatingPhase) {
        guard stage.kind == .merge, s.state == .gating, s.gatingPhase == phase else { return ignore("no merge in progress") }
        guard let target = stage.conflictReturn(in: pipeline) else { return waitHuman(.conflictLimit, note: "no agent stage for conflicts") }
        bounce(key: TaskMachineState.conflictBounceKey, limit: target.limit, limitReason: .conflictLimit, target: target.stage,
               prompt: [prompt], returnReason: .mergeConflict, runId: nil)
    }

    mutating func mainDirty() {
        guard s.state == .gating, s.gatingPhase == .fastForward else { return ignore("not fast-forwarding") }
        set(.blocked(.mainDirty))
    }

    mutating func mainCleaned() {
        guard s.state == .blocked(.mainDirty) else { return ignore("not blocked") }
        s.gatingPhase = .fastForward
        set(.gating)
        effects.append(.fastForwardMerge)
    }

    /// The recorded rebase base is gone. Go back to rebase; the fast-forward must not replace the new `main`.
    mutating func mainMoved(_ stage: StageConfig) {
        guard s.state == .gating, s.gatingPhase == .fastForward else { return ignore("not fast-forwarding") }
        s.gatingPhase = .rebase
        set(.gating)
        effects.append(.startMerge(stageId: stage.id, gates: stage.gates))
    }

    mutating func merged(_ stage: StageConfig) {
        guard s.state == .gating, s.gatingPhase == .fastForward else { return ignore("not fast-forwarding") }
        enter(stage.onSuccess, priority: nil, prompt: [], returnReason: nil, note: "merged")
    }

    // MARK: Returns

    /// Automatic return with per-route and total limits. Over a limit the task stays and waits for a human.
    mutating func bounce(key: String, limit: Int, limitReason: WaitingHumanReason, target: StageID, prompt: [PromptAddition],
                         returnReason: ReturnReason, runId: RunID?) {
        let count = (s.bounces[key] ?? 0) + 1
        if count > limit {
            return waitHuman(limitReason, note: "\(key): limit \(limit) reached", runId: runId)
        }
        if s.totalBounces + 1 > pipeline.board.bounceLimitTotal {
            return waitHuman(.bounceLimit, note: "bounce_limit_total \(pipeline.board.bounceLimitTotal) reached", runId: runId)
        }
        s.bounces[key] = count
        s.totalBounces += 1
        enter(target, priority: .returned, prompt: prompt, returnReason: returnReason, note: key, runId: runId)
    }

    // MARK: Stage entry & waiting

    /// New stage entry: attempt counters reset, task waits in `queued` (or is `done` at a terminal stage).
    mutating func enter(_ target: StageID?, priority: QueuePriority?, prompt: [PromptAddition], returnReason: ReturnReason?,
                        note: String?, runId: RunID? = nil) {
        guard let target, let next = pipeline.stage(target) else { return waitHuman(.incident, note: "no next stage") }
        s.stageId = target
        s.attemptsUsed = 0
        s.extraAttempts = 0
        s.invalidResultStrikes = 0
        s.silentExitPending = false
        s.gatingPhase = nil
        s.priority = priority
        s.pendingPrompt = prompt
        s.returnReason = returnReason
        s.resumeSession = false
        if next.kind == .terminal {
            set(.done, note: note, runId: runId)
            effects.append(.expireGitGrants(.taskDone))
            effects.append(.cleanupClone(keepBranch: false))
        } else {
            set(.queued(nil), note: note, runId: runId)
        }
    }

    mutating func waitHuman(_ reason: WaitingHumanReason, note: String? = nil, runId: RunID? = nil) {
        set(.waitingHuman(reason), note: note, runId: runId)
        effects.append(.notifyHuman(reason))
    }

    // MARK: Human commands

    mutating func human(_ stage: StageConfig, _ action: HumanAction) {
        switch action {
        case .answer(let text, let requestId): answer(stage, text: text, requestId: requestId)
        case .approve: approve(stage)
        case .requestChanges(let comments, let target): requestChanges(stage, comments: comments, target: target, acceptSet: false)
        case .reject(.cancel, let keep): cancel(keepBranch: keep)
        case .reject(.stage(let target), _): requestChanges(stage, comments: nil, target: target, acceptSet: true)
        case .pause: pause()
        case .resume: resume()
        case .move(let target): humanMove(target)
        case .retryStage(let grant): retryStage(stage, grant: grant)
        case .cancel(let keep): cancel(keepBranch: keep)
        case .acceptSuspiciousFiles(let shown): acceptSuspicious(stage, shown: shown)
        }
        if case .applied = outcome { s.runsSinceHuman = 0 }
    }

    /// Leaving `waiting_human` by a human command: resolves the incident; accepts the suspicious set unless `acceptSet` is false.
    mutating func leaveWaiting(acceptSet: Bool = true) {
        if case .waitingHuman(.incident) = original.state, s.openIncident != nil {
            effects.append(.resolveIncident)
            s.openIncident = nil
        }
        if case .waitingHuman(.suspiciousFiles) = original.state, !original.suspiciousFiles.isEmpty {
            if acceptSet { effects.append(.acceptSuspiciousFiles(original.suspiciousFiles)) }
            s.suspiciousFiles = []
        }
    }

    mutating func killLiveRun() {
        if s.state == .running, let run = s.currentRunId { effects.append(.killRun(run)) }
    }

    mutating func answer(_ stage: StageConfig, text: String, requestId: HumanRequestID?) {
        guard case .waitingHuman(let reason) = s.state else { return reject("answerHuman needs a task in waiting_human") }
        guard stage.kind == .agent else {
            return reject("answerHuman: stage '\(stage.id)' has no agent; use retryStage, moveTask, requestChanges or reject")
        }
        _ = reason
        // «Ask to remove the file» does NOT accept the suspicious set: the next run's gates re-check it.
        leaveWaiting(acceptSet: false)
        if s.attemptsExhausted(stage) { s.extraAttempts += 1 }
        effects.append(.recordHumanAnswer(text: text, requestId: requestId))
        s.priority = .answered
        s.pendingPrompt.append(.humanAnswer(text))
        s.resumeSession = true
        set(.queued(nil))
    }

    mutating func approve(_ stage: StageConfig) {
        guard stage.kind == .human, s.state == .waitingHuman(.review) else {
            return reject("approve is only for tasks under review in a human stage")
        }
        enter(stage.onSuccess, priority: nil, prompt: [], returnReason: nil, note: "approved")
    }

    /// `requestChanges` never accepts the suspicious set (v0.11.2 §8.2): the check repeats after the target's gates.
    /// `reject` to a stage does accept it. Both are returns (v0.11.6 §3.1, §3.3): the target must be a writable agent
    /// stage (else `invalid_state`); `requestChanges` without target goes to `defaultReturnStage`. `reject` to cancel is separate.
    mutating func requestChanges(_ stage: StageConfig, comments: String?, target: StageID?, acceptSet: Bool) {
        guard case .waitingHuman = s.state else { return reject("requestChanges/reject needs a task in waiting_human") }
        guard let targetId = target ?? pipeline.defaultReturnStage else {
            return reject("No writable agent stage to return the task to")
        }
        guard let t = pipeline.stage(targetId) else {
            return reject("Unknown target stage '\(target?.rawValue ?? "-")'", code: CommandError.notFoundCode)
        }
        guard t.kind != .terminal, t.id == stage.id || pipeline.isUpstream(t.id, of: stage.id) else {
            return reject("Target '\(t.id)' must be the current or an earlier stage")
        }
        // Only a writable agent stage qualifies (`invalid_state`); `moveTask` is a move and is not restricted.
        if !t.isReturnTarget {
            return reject("'\(t.id)' is not a writable agent stage; a task can only be returned to one")
        }
        leaveWaiting(acceptSet: acceptSet)
        // Human returns do not count toward return limits.
        enter(t.id, priority: .returned, prompt: comments.map { [.humanComments($0)] } ?? [], returnReason: .human, note: "changes requested")
    }

    mutating func pause() {
        switch s.state {
        case .queued, .running, .gating, .retryWait, .waitingHuman(.review):
            s.pausedState = s.state
            killLiveRun()
            set(.paused)
        default:
            reject("pauseTask: cannot pause a task in \(s.state.status.rawValue)")
        }
    }

    mutating func resume() {
        guard s.state == .paused else { return reject("resumeTask: task is not paused") }
        let restored: TaskState = s.pausedState == .waitingHuman(.review) ? .waitingHuman(.review) : .queued(nil)
        s.pausedState = nil
        set(restored)
    }

    mutating func humanMove(_ target: StageID) {
        guard let t = pipeline.stage(target) else { return reject("Unknown stage '\(target)'", code: CommandError.notFoundCode) }
        guard t.kind != .terminal else { return reject("moveTask cannot move into a terminal stage; approve and merge instead") }
        killLiveRun()
        leaveWaiting()
        enter(t.id, priority: nil, prompt: [], returnReason: .human, note: "moved")
    }

    mutating func retryStage(_ stage: StageConfig, grant: Int?) {
        guard case .waitingHuman(let reason) = s.state, reason != .review else {
            return reject("retryStage needs a task in waiting_human (not review)")
        }
        if let grant, grant < 0 { return reject("grantAttempts must be ≥ 0") }
        let extra = s.extraAttempts.addingReportingOverflow(grant ?? 0)
        let limit = stage.retry.maxAttempts.addingReportingOverflow(extra.partialValue)
        guard !extra.overflow, !limit.overflow else { return reject("grantAttempts exceeds the supported attempt counter") }
        let exhausted = s.attemptsUsed >= limit.partialValue
        guard !exhausted || limit.partialValue < Int.max else { return reject("No further attempt fits the supported counter") }
        leaveWaiting()
        s.extraAttempts = extra.partialValue + (exhausted ? 1 : 0)
        s.invalidResultStrikes = 0
        set(.queued(nil))
    }

    mutating func cancel(keepBranch: Bool) {
        killLiveRun()
        leaveWaiting()
        s.gatingPhase = nil
        set(.cancelled)
        effects.append(.expireGitGrants(.taskCancelled))
        effects.append(.cleanupClone(keepBranch: keepBranch))
    }

    mutating func acceptSuspicious(_ stage: StageConfig, shown: [FileBlobRef]) {
        guard s.state == .waitingHuman(.suspiciousFiles) else {
            return reject("acceptSuspiciousFiles: task is not waiting on suspicious files", code: CommandError.staleSuspiciousFilesCode)
        }
        guard SuspiciousFilesScanner.sameSet(s.suspiciousFiles, shown) else {
            return reject("The suspicious file set changed; reload and review it again", code: CommandError.staleSuspiciousFilesCode)
        }
        // Accept, then the daemon re-checks the diff; a clean check performs the blocked transition. No run, no attempt.
        effects.append(.acceptSuspiciousFiles(s.suspiciousFiles))
        s.suspiciousFiles = []
        s.gatingPhase = .resultCheck
        set(.gating, note: "suspicious files accepted")
        effects.append(.runResultCheck(stageId: stage.id))
    }
}
