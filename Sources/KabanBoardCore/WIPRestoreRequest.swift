import Foundation
import KabanProtocol

/// Bind confirmation to the exact task, run/ref and pipeline the person reviewed.
/// This is a UI availability check; the daemon authorizes and performs the git effect.
public struct WIPRestoreRequest: Equatable, Sendable {
    public let card: TaskCard
    public let run: RunSummary
    public let pipeline: PipelineSummary?
    public init(card: TaskCard, run: RunSummary, pipeline: PipelineSummary?) {
        self.card = card; self.run = run; self.pipeline = pipeline
    }
    public var isAvailable: Bool {
        guard let pipeline, pipeline.projectId == card.projectId,
              pipeline.stages.first(where: { $0.id == card.stageId })?.kind == .agent,
              run.taskId == card.id, let ref = run.wipRef, !ref.isEmpty else { return false }
        return [.queued, .retryWait, .paused, .waitingHuman].contains(card.state.status)
    }
    public func command(current: TaskCard?, history: [RunSummary], pipeline: PipelineSummary?) -> Command? {
        guard isAvailable, current == card, self.pipeline == pipeline,
              history.contains(run), let ref = run.wipRef else { return nil }
        return .restoreWIP(taskId: card.id, runId: run.id, wipRef: ref)
    }
}
