import Foundation
import KabanProtocol

/// Everything the state machine needs to know about one task. Pure value; `KabanDaemonCore` persists it.
public struct TaskMachineState: Codable, Hashable, Sendable {
    public var taskId: TaskID
    public var stageId: StageID
    public var state: TaskState

    /// Charged attempts in the current stage entry (§3.2 «Счётчики»). Reset on every stage entry.
    public var attemptsUsed: Int
    /// Attempts granted by a human (`retryStage(grantAttempts)`, `answerHuman` on exhausted limits) in this entry.
    public var extraAttempts: Int
    /// Automatic runs since the last human action (`max_runs_per_task`). Counted when a run starts (so a live run is
    /// included, as on the card) and refunded when it ends without charging (rate limit, auth, restart, silent exit,
    /// model substitution, quota/model flag).
    public var runsSinceHuman: Int

    /// Run currently alive (`running`) — events of other runs are stale and ignored.
    public var currentRunId: RunID?
    /// Last run of the task (for idempotent repeats of MCP calls and for clone rollback refs).
    public var lastRunId: RunID?
    /// Sub-phase while `gating` (or `blocked` in merge).
    public var gatingPhase: GatingPhase?

    /// Automatic return counters, key = `"<from>_<to>"` for `returns_to`/`on_fail`, `merge_conflict` for conflicts.
    public var bounces: [String: Int]
    public var totalBounces: Int

    public var returnReason: ReturnReason?
    public var priority: QueuePriority?
    /// Context the next agent run must get in its prompt (gate output, reminder, human answer, return issues).
    public var pendingPrompt: [PromptAddition]
    /// Next agent run should `--resume` the saved session (after `request_human` answers).
    public var resumeSession: Bool
    /// `silent_exit` waits for a model probe; the attempt is charged only if the probe comes back clean.
    public var silentExitPending: Bool
    /// Read-only stage left changes: first time → rollback + retry, second time in the entry → `invalid_result`.
    public var invalidResultStrikes: Int
    /// `summary` of the last `complete_stage` (strict preset: daemon commit message, §6.3).
    public var lastSummary: String?
    /// Current unaccepted set; non-empty only in `waiting_human: suspicious_files` (mirrors `TaskCard.suspiciousFiles`).
    public var suspiciousFiles: [SuspiciousFile]
    public var openIncident: IncidentKind?

    public init(taskId: TaskID, stageId: StageID, state: TaskState = .queued(nil)) {
        self.taskId = taskId; self.stageId = stageId; self.state = state
        attemptsUsed = 0; extraAttempts = 0; runsSinceHuman = 0
        currentRunId = nil; lastRunId = nil; gatingPhase = nil
        bounces = [:]; totalBounces = 0
        returnReason = nil; priority = nil; pendingPrompt = []; resumeSession = false
        silentExitPending = false; invalidResultStrikes = 0; lastSummary = nil
        suspiciousFiles = []; openIncident = nil
    }

    /// New task in the pipeline's entry (`queue`) stage.
    public static func new(taskId: TaskID, pipeline: PipelineConfig) -> TaskMachineState? {
        pipeline.entryStage.map { TaskMachineState(taskId: taskId, stageId: $0.id) }
    }

    /// Key of `bounces` / `TaskCard.bounceByReason` for an automatic return route, e.g. `test_dev`.
    public static func bounceKey(from: StageID, to: StageID) -> String { "\(from.rawValue)_\(to.rawValue)" }
    public static let conflictBounceKey = "merge_conflict"

    /// 1-based number of the current (or next) attempt for the card (`2/3`); stays at the limit once exhausted.
    public func displayAttempt(_ stage: StageConfig) -> Int { min(attemptsUsed + 1, max(attemptLimit(stage), 1)) }

    /// Fills the state-machine-owned fields of a board card.
    public func apply(to card: inout TaskCard, stage: StageConfig?) {
        card.stageId = stageId
        card.state = state
        card.runsSinceHuman = runsSinceHuman
        card.bounceByReason = bounces
        card.suspiciousFiles = suspiciousFiles
        if let stage, stage.kind == .agent || stage.kind == .gate || stage.kind == .merge {
            card.attempt = displayAttempt(stage)
            card.maxAttempts = attemptLimit(stage)
        } else {
            card.attempt = 0
            card.maxAttempts = nil
        }
    }

    public func attemptLimit(_ stage: StageConfig) -> Int { stage.retry.maxAttempts + extraAttempts }
    public func attemptsExhausted(_ stage: StageConfig) -> Bool { attemptsUsed >= attemptLimit(stage) }
}

public enum GatingPhase: String, Codable, Hashable, Sendable {
    /// Stage gate commands (agent after `complete_stage`, or a `gate` stage).
    case gates
    /// Daemon result check (§8.2 layer 4 + suspicious files).
    case resultCheck = "result_check"
    /// Merge stage: fetch + rebase in the merge clone + gates.
    case rebase
    /// Merge stage: fast-forward of `main`.
    case fastForward = "fast_forward"
}

public enum QueuePriority: String, Codable, Hashable, Sendable { case returned, answered }

public enum PromptAddition: Codable, Hashable, Sendable {
    case gateOutput(String)
    /// `no_final_call`: remind to finish via `complete_stage` / `return_to_stage` / `request_human`.
    case finishReminder
    case humanAnswer(String)
    case humanComments(String)
    case returnIssues(from: StageID, issues: [String])
    case mergeConflict(files: [String])
    case readOnlyViolation
}

// MARK: - Events

/// Inputs of the state machine: scheduler decisions, MCP calls of the agent, daemon observations, human commands.
public enum TaskEvent: Hashable, Sendable {
    // Scheduler
    /// A slot was granted. Agent stage → new run `runId`; gate/merge → gating; human → review; queue → intake.
    case start(runId: RunID)
    /// Start refused before a run is created; the task waits in `queued` without holding a WIP slot.
    case startBlocked(StartBlock)

    // Agent (board MCP), always bound to a run
    case completeStage(runId: RunID, summary: String)
    case returnToStage(runId: RunID, target: StageID, issues: [String])
    case requestHuman(runId: RunID, question: String)

    // Daemon: run lifecycle
    case runEnded(runId: RunID, RunFailure)
    /// `system/init` reported another model; the run is killed before the first tool call (§6.4).
    case modelMismatch(runId: RunID, requested: String, actual: String, fallback: String?)
    /// Fifth git denial in a run (§8.3).
    case gitDenialLimit(runId: RunID)
    case daemonRestarted
    /// Outcome of the model probe after `silent_exit` (§6.4).
    case probeFinished(ProbeOutcome)

    // Daemon: gates, result check, merge
    case gatesPassed
    case gatesFailed(output: String)
    case resultChecked(ResultCheck)
    case mergeConflict(files: [String])
    case mainDirty
    case mainCleaned
    case merged

    case human(HumanAction)
}

public enum StartBlock: Hashable, Sendable {
    case wipFull
    case quota(ModelPool)
    case modelFlag
}

/// How a run ended without a final MCP call (`run.end_reason`).
public enum RunFailure: Hashable, Sendable {
    case crash, stallTimeout, wallTimeout, noFinalCall
    case rateLimit, runnerAuth, silentExit
    /// Monthly quota; `nil` pool = unknown (whole Mac).
    case usageExhausted(ModelPool?)
    /// `resource_exhausted` / not in the slow pool → model flag `unavailable`.
    case modelUnavailable

    /// Charges an attempt and counts toward `max_runs_per_task` (§3.2, decisions log).
    public var charges: Bool {
        switch self {
        case .crash, .stallTimeout, .wallTimeout, .noFinalCall: true
        case .rateLimit, .runnerAuth, .silentExit, .usageExhausted, .modelUnavailable: false
        }
    }
}

public enum ProbeOutcome: Hashable, Sendable {
    /// No limit found: the silent exit was an ordinary failure, the attempt is charged retroactively.
    case clean
    case rateLimit
    case usageExhausted(ModelPool?)
    case modelUnavailable
}

public enum ResultCheck: Hashable, Sendable {
    case clean
    case suspiciousFiles([SuspiciousFile])
    case incident(IncidentKind)
    /// A read-only stage left changes in the clone.
    case readOnlyChanges
}

public enum HumanAction: Hashable, Sendable {
    case answer(text: String, requestId: HumanRequestID?)
    case approve
    case requestChanges(comments: String, target: StageID?)
    case reject(target: RejectTarget, keepBranch: Bool)
    case pause
    case resume
    case move(stage: StageID)
    case retryStage(grantAttempts: Int?)
    case cancel(keepBranch: Bool)
    case acceptSuspiciousFiles([FileBlobRef])

    public init?(command: Command) {
        switch command {
        case .answerHuman(_, let text, let requestId): self = .answer(text: text, requestId: requestId)
        case .approve: self = .approve
        case .requestChanges(_, let comments, let target): self = .requestChanges(comments: comments, target: target)
        case .reject(_, let target, let keepBranch): self = .reject(target: target, keepBranch: keepBranch)
        case .pauseTask: self = .pause
        case .resumeTask: self = .resume
        case .moveTask(_, let stage): self = .move(stage: stage)
        case .retryStage(_, let grant): self = .retryStage(grantAttempts: grant)
        case .cancelTask(_, let keepBranch): self = .cancel(keepBranch: keepBranch)
        case .acceptSuspiciousFiles(_, let files): self = .acceptSuspiciousFiles(files)
        default: return nil
        }
    }
}

// MARK: - Effects

/// Side effects the daemon executes after persisting the new state in the same transaction (journal first).
public enum TaskEffect: Codable, Hashable, Sendable {
    /// Journal `taskTransitioned` (plus `taskUpdated` with the card, see `TaskMachineState.apply(to:stage:)`).
    case recordTransition(TaskTransition)
    case startAgentRun(AgentRunRequest)
    /// Kill the run's process group; no attempt is charged unless a later event says so.
    case killRun(RunID)
    /// Save dirty clone state to `refs/kaban/wip/<run-id>` (inside the clone) and reset to the last stage commit.
    case saveWipAndRollback(RunID)
    case runGates(stageId: StageID, commands: [String])
    case runResultCheck(stageId: StageID)
    /// Merge stage: fetch task branch, rebase onto `main` in the merge clone, run gates (§8.5).
    case startMerge(stageId: StageID, gates: [String])
    case fastForwardMerge
    case commitStage(StageCommit)
    case scheduleRetry(afterSeconds: Int, reason: RetryWaitReason)
    /// Global short rate limit; the scheduler picks the cooldown step (15 → 30 → 60 min).
    case raiseRateLimit
    case raiseRunnerUnavailable(RunnerUnavailableReason)
    case raiseUsageExhausted(ModelPool?)
    case raiseModelFlag(ModelFlagRequest)
    case requestModelProbe(ModelID)
    case recordHumanRequest(question: String, runId: RunID)
    case recordHumanAnswer(text: String, requestId: HumanRequestID?)
    case openIncident(IncidentKind, runId: RunID?)
    case resolveIncident
    /// Journal `suspiciousFilesFound` + `taskUpdated` (card carries the set) in the same transaction.
    case reportSuspiciousFiles([SuspiciousFile], runId: RunID?)
    /// Write `task_accepted_file` rows and journal `suspiciousFilesAccepted` + `taskUpdated`.
    case acceptSuspiciousFiles([SuspiciousFile])
    case notifyHuman(WaitingHumanReason)
    case expireGitGrants(GitGrantExpiryReason)
    /// Archive the branch as `kaban/archive/<task-id>` (if `keepBranch`) and delete the clone (delayed after `done`).
    case cleanupClone(keepBranch: Bool)
}

public struct AgentRunRequest: Codable, Hashable, Sendable {
    public var runId: RunID
    public var stageId: StageID
    public var model: ModelID
    /// 1-based attempt number within the stage entry (`2/3` on the card).
    public var attempt: Int
    public var maxAttempts: Int
    public var readOnly: Bool
    /// Continue in the same clone without rollback (after `gate_failed` / `no_final_call`, §6.1).
    public var continueInClone: Bool
    public var resumeSession: Bool
    public var prompt: [PromptAddition]
    public var returnReason: ReturnReason?
}

public struct ModelFlagRequest: Codable, Hashable, Sendable {
    public var modelId: ModelID
    public var reason: ModelFlag.Reason
    public var requested: String?
    public var actual: String?
    public var fallbackModel: String?
}

public enum StageCommit: Codable, Hashable, Sendable {
    /// `strict`: the only commit of the stage, message = `complete_stage.summary`.
    case daemonSingle(summary: String)
    /// `standard` / `permissive`: safety commit `kaban: <stage> <task>` if anything is left uncommitted.
    case safety
}

public enum TransitionOutcome: Hashable, Sendable {
    case applied
    /// Stale or irrelevant event (e.g. from a killed run); nothing changes, nothing to report.
    case ignored(String)
    /// Illegal command or MCP call; reply with this error, nothing changes.
    case rejected(CommandError)
}

public struct TransitionResult: Hashable, Sendable {
    public var state: TaskMachineState
    public var effects: [TaskEffect]
    public var outcome: TransitionOutcome
}
