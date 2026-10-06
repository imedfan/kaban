import Foundation
import KabanKit
import KabanProtocol

/// The first headless command surface. Real process/git/gate execution is a later layer.
public enum DurableTaskCommand: Codable, Hashable, Sendable {
    case start(RunID)
    case startBlocked(QueuedReason)
    case completeStage(RunID, summary: String)
    case returnToStage(RunID, target: StageID, issues: [String])
    case requestHuman(RunID, question: String)
    case answer(text: String, requestId: HumanRequestID?)
    case approve
    case requestChanges(comments: String, target: StageID?)
    case reject(target: RejectTarget, keepBranch: Bool)
    case move(StageID)
    case retryStage(grantAttempts: Int?)
    case pause
    case resume
    case resultClean
    case resultReadOnly
    case gatesPassed
    case daemonRestarted
    case cancel(keepBranch: Bool)
    case runFailed(RunID, RunFailure)
    case modelMismatch(runId: RunID, requested: String, actual: String, fallback: String?)
    case gatesFailed(output: String)

    var event: TaskEvent {
        switch self {
        case .start(let id): .start(runId: id)
        case .startBlocked(let reason):
            .startBlocked(reason == .wipFull ? .wipFull : reason == .modelFlag ? .modelFlag : .quota(reason == .quotaCm ? .cm : .om))
        case .completeStage(let id, let summary): .completeStage(runId: id, summary: summary)
        case .returnToStage(let id, let target, let issues): .returnToStage(runId: id, target: target, issues: issues)
        case .requestHuman(let id, let question): .requestHuman(runId: id, question: question)
        case .answer(let text, let request): .human(.answer(text: text, requestId: request))
        case .approve: .human(.approve)
        case .requestChanges(let comments, let target): .human(.requestChanges(comments: comments, target: target))
        case .reject(let target, let keep): .human(.reject(target: target, keepBranch: keep))
        case .move(let stage): .human(.move(stage: stage))
        case .retryStage(let grant): .human(.retryStage(grantAttempts: grant))
        case .pause: .human(.pause)
        case .resume: .human(.resume)
        case .resultClean: .resultChecked(.clean)
        case .resultReadOnly: .resultChecked(.readOnlyChanges)
        case .gatesPassed: .gatesPassed
        case .daemonRestarted: .daemonRestarted
        case .cancel(let keep): .human(.cancel(keepBranch: keep))
        case .runFailed(let id, let failure): .runEnded(runId: id, failure)
        case .modelMismatch(let id, let requested, let actual, let fallback):
            .modelMismatch(runId: id, requested: requested, actual: actual, fallback: fallback)
        case .gatesFailed(let output): .gatesFailed(output: output)
        }
    }
}

public struct DurableTask: Codable, Hashable, Sendable {
    public var card: TaskCard
    public var machine: TaskMachineState
    /// Rules of the current invocation/stage entry. Replacement only takes effect at a new start.
    public var pipeline: PipelineConfig
    public var pipelineVersion: String? = nil
    public var runSpecId: RunID? = nil
}

/// Exact versioned effect payloads are durable; upgrades never recompute old effects.
public struct PendingEffectBatch: Codable, Hashable, Sendable {
    public let version: Int
    public let commandId: CommandID
    public let taskId: TaskID
    public let effects: [TaskEffect]
    public var runSpecId: RunID? = nil
}

public struct DurableReceipt: Codable, Hashable, Sendable {
    public let commandId: CommandID
    public let firstSeq: Seq?
    public let lastSeq: Seq
    public let task: DurableTask
}

public struct DurableSnapshot: Sendable {
    public let seq: Seq
    public let tasks: [DurableTask]
}

public enum StoreError: Error, Equatable {
    case taskExists, taskMissing, invalidPipeline, commandIdConflict
    case projectMissing, incompleteProjection, settingsInvalid, schedulerBlocked
    case effectMissing, effectSuperseded, effectLeaseStale, unsupportedEffect, effectResultConflict
    case questionInvalid
    case rejected(CommandError)
}
