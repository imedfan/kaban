import Foundation
import KabanProtocol

/// The drag carries a source snapshot, never a new location or optimistic state.
public struct TaskDragItem: Codable, Equatable, Sendable {
    public let card: TaskCard
    public let pipelineVersion: String?
    public let generation: UUID
    public init(card: TaskCard, pipelineVersion: String?, generation: UUID) {
        self.card = card; self.pipelineVersion = pipelineVersion; self.generation = generation
    }
    public func decision(current: TaskCard?, target: StageSummary, pipeline: PipelineSummary, generation: UUID) -> DropDecision {
        guard pipeline.projectId == card.projectId else { return .forbidden(.crossProject) }
        guard self.generation == generation, current == card else { return .forbidden(.staleTask) }
        guard let pipelineVersion, !pipelineVersion.isEmpty else { return .forbidden(.unknownPipelineVersion) }
        guard pipeline.versionHash == pipelineVersion else { return .forbidden(.staleTask) }
        return TaskActions.moveDecision(card: card, target: target, pipeline: pipeline)
    }
}

/// A confirmation remains bound to the exact task the person reviewed.
public struct TaskControlRequest: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case pause, resume, move(StageID?), retry, cancel
    }
    public let card: TaskCard
    public let action: Action
    public init(card: TaskCard, action: Action) { self.card = card; self.action = action }
    public func command(current: TaskCard?, pipeline: PipelineSummary?, target: StageID? = nil,
                        keepBranch: Bool = false, grantAttempts: Int? = nil) -> Command? {
        guard let current, current == card else { return nil }
        switch action {
        case .pause: return TaskActions.canPause(current) ? .pauseTask(taskId: card.id) : nil
        case .resume: return TaskActions.canResume(current) ? .resumeTask(taskId: card.id) : nil
        case .cancel: return TaskActions.canCancel(current) ? .cancelTask(taskId: card.id, keepBranch: keepBranch) : nil
        case .retry:
            guard TaskActions.canRetry(current), grantAttempts.map({ $0 >= 0 }) ?? true else { return nil }
            return .retryStage(taskId: card.id, grantAttempts: grantAttempts)
        case .move(let suggested):
            guard let pipeline, let id = target ?? suggested, let stage = pipeline.stages.first(where: { $0.id == id }),
                  TaskActions.moveDecision(card: current, target: stage, pipeline: pipeline).isAllowed else { return nil }
            return .moveTask(taskId: card.id, stage: id)
        }
    }
}
