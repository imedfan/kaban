import Foundation
import KabanKit
import KabanProtocol

/// The first headless command surface. Real process/git/gate execution is a later layer.
public enum DurableTaskCommand: Codable, Hashable, Sendable {
    case start(RunID)
    case completeStage(RunID, summary: String)
    case gatesPassed
    case daemonRestarted
    case cancel(keepBranch: Bool)

    var event: TaskEvent {
        switch self {
        case .start(let id): .start(runId: id)
        case .completeStage(let id, let summary): .completeStage(runId: id, summary: summary)
        case .gatesPassed: .gatesPassed
        case .daemonRestarted: .daemonRestarted
        case .cancel(let keep): .human(.cancel(keepBranch: keep))
        }
    }
}

public struct DurableTask: Codable, Hashable, Sendable {
    public var card: TaskCard
    public var machine: TaskMachineState
    /// Immutable creation snapshot; pipeline replacement/stage-entry versioning follows in M1.
    public let pipeline: PipelineConfig
}

/// Exact versioned effect payloads are durable; upgrades never recompute old effects.
public struct PendingEffectBatch: Codable, Hashable, Sendable {
    public let version: Int
    public let commandId: CommandID
    public let taskId: TaskID
    public let effects: [TaskEffect]
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
    case rejected(CommandError)
}
