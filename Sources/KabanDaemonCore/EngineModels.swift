import Foundation
import KabanKit
import KabanProtocol

public struct ConfigurationReceipt: Codable, Hashable, Sendable {
    public let commandId: CommandID
    public let seq: Seq
}

public struct PendingEffect: Codable, Hashable, Sendable {
    public let version: Int
    public let id: String
    public let commandId: CommandID
    public let taskId: TaskID
    public let index: Int
    public let effect: TaskEffect
    public var runSpecId: RunID? = nil
}

/// Fake results are values, never evidence of a real process or git operation.
public enum FakeEffectResult: Codable, Hashable, Sendable {
    case question(String)
    case completed(summary: String)
    case gatesPassed
    case clean
    case acknowledged
}

public struct EffectReceipt: Codable, Hashable, Sendable {
    public let effectId: String
    public let seq: Seq
    public let task: DurableTask
}

/// Lease returned only after the claim transaction has committed.
public struct EffectLease: Codable, Hashable, Sendable {
    public let effectId: String
    public let leaseId: String
    public let owner: String
    public let fencing: Int
    public let expiresAt: Date
    public let payload: PendingEffect
}

/// Fact observed outside SQLite. A finished fact can be reconciled into one receipt.
public struct ExternalEffectFact: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable { case started, finished }
    public let actionId: String
    public let phase: Phase
    public var outcome: RealEffectOutcome?
    public init(actionId: String, phase: Phase, outcome: RealEffectOutcome? = nil) {
        self.actionId = actionId
        self.phase = phase
        self.outcome = outcome
    }
}

/// Live result of a real effect. This is not a `FakeEffectResult` and is never written by `deliverFake`.
public enum RealEffectOutcome: Codable, Hashable, Sendable {
    case acknowledged
    case completed(summary: String)
    case question(String)
    case gatesPassed
    case gatesFailed(output: String)
    case clean
    case readOnlyChanges
    case suspiciousFiles([SuspiciousFile])
    case incident(IncidentKind, rolledBack: [String])
    case mergeConflict([String])
    case mainDirty
    case mainMoved
    case merged
}

public enum EffectExecutionDiagnostic {
    public static let reclaim = "external action was not observed; reclaim does not promise the process ran at most once"
    public static let observedUnfinished = "external action was observed; the effect was not restarted and has no receipt yet"
    public static let protocolReceipt = "BE-05 protocol receipt; process, git, clone, and notification actions are not performed"
}

public struct TickReceipt: Codable, Hashable, Sendable {
    public let tickId: UUID
    public let transitions: [DurableReceipt]
    public let seq: Seq
}

struct ProductionProject: Codable {
    var repositoryID: String
    var pipelineSummary: PipelineSummary
    var unavailableReason: ProjectUnavailableReason?
    var source: PipelineSource? = nil
}
struct ProjectRecord: Codable {
    var summary: ProjectSummary
    var pipeline: PipelineConfig
    var version: String
    var production: ProductionProject? = nil
    var projectedPipeline: PipelineSummary {
        production?.pipelineSummary ?? pipeline.summary(projectId: summary.id, versionHash: version,
            issues: PipelineValidator.validate(config: pipeline).issues)
    }
}
struct StoredQuestion: Codable { let request: HumanRequest; var answeredAt: Date?; var answer: String? }
struct StoredDetail: Codable {
    var body: String?
    var feed: [FeedItem] = []
    var runs: [RunSummary] = []
    var questions: [StoredQuestion] = []
    // These are persisted even while lifecycle recording is outside this bounded engine.
    var artifacts: [TaskArtifact] = []
    var gitGrants: [GitGrantSnapshot] = []
    var gitDenials: [GitDenialSnapshot] = []
    var acceptedFiles: [AcceptedFile] = []
    var clonePath: String?
}

struct SchedulerCursor: Codable { var project: ProjectID?; var remaining: Int = 0 }
