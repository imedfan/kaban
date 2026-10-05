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
