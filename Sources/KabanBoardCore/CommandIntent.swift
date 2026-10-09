import Foundation
import KabanProtocol

/// The client serializes user intent by its actual resource, independently of
/// whether the server has acknowledged the request or applied its journal event.
public enum CommandScope: Codable, Hashable, Sendable {
    case task(TaskID)
    case project(ProjectID)
    case pipeline(ProjectID)
    case grant(GrantID)
    case denial(DenialID)
    case model(ModelID)
    case global
}

public extension Command {
    var mutationScope: CommandScope? {
        switch self {
        case .getTaskDetail, .getRunHistory, .listBranches, .detectGates,
             .validatePipeline, .validatePipelineDraft, .getPipelineSource, .checkEnvironment,
             .getCursorEnvironment, .listModels, .listProjectMcpServers, .listIncidents:
            nil
        case .createTask(let id, _, _): .project(id)
        case .editTask(let id, _, _), .setPriority(let id, _), .moveTask(let id, _),
             .pauseTask(let id), .resumeTask(let id), .cancelTask(let id, _),
             .retryStage(let id, _), .setModelOverride(let id, _, _),
             .restoreWIP(let id, _, _), .answerHuman(let id, _, _), .approve(let id),
             .requestChanges(let id, _, _), .reject(let id, _, _),
             .acceptSuspiciousFiles(let id, _): .task(id)
        case .setProjectIdentity(let id, _), .removeProject(let id),
             .relinkProject(let id, _), .setMascot(let id, _),
             .setProjectWeight(let id, _, _), .pauseProject(let id),
             .resumeProject(let id), .setProjectMcpAllowlist(let id, _): .project(id)
        case .updatePipeline(let id, _, _): .pipeline(id)
        case .allowGitOnce(let id), .addDenialToPolicy(let id, _, _): .denial(id)
        case .revokeGitGrant(let id): .grant(id)
        case .clearModelFlag(let id): .model(id)
        case .recheck(.project(let id)): .project(id)
        case .addProject, .pauseAll, .resumeAll, .resumeAfterRateLimit,
             .setMaxConcurrentRuns, .configureCursor, .recheck(.runner),
             .refreshModelCatalog, .setModelPoolRule, .removeModelPoolRule,
             .setQuotaOptions: .global
        }
    }

    /// An unrelated event carrying the same commandId cannot resolve an intent.
    /// Restore is special: its receipt queues git work; only wipRestored proves
    /// successful completion, never taskUpdated or snapshot coverage alone.
    func isConfirmed(by event: JournalEvent) -> Bool {
        switch (self, event) {
        case (.createTask(let project, _, _), .taskCreated(let card)):
            card.projectId == project
        case (.editTask(let id, _, _), .taskEdited(let card)):
            card.id == id
        case (.restoreWIP(let id, let run, let ref), .wipRestored(let value)):
            value.taskId == id && value.runId == run && value.wipRef == ref
        case (.restoreWIP, _), (.createTask, _), (.editTask, _): false
        case (_, .taskUpdated(let card)):
            mutationScope == .task(card.id)
        case (.addProject, .projectAdded): true
        case (.removeProject(let id), .projectRemoved(let removed)): id == removed
        case (_, .projectUpdated(let project)):
            mutationScope == .project(project.id)
        case (.updatePipeline(let id, _, _), .pipelineApplied(let pipeline)):
            pipeline.projectId == id
        case (.allowGitOnce(let id), .gitGrantCreated(let value)): value.denialId == id
        case (.revokeGitGrant(let id), .gitGrantRevoked(let value)): value.grantId == id
        case (.addDenialToPolicy(_, let scope, let draft), .gitPolicyUpdated(let value)):
            value.scope == scope && draft?.projectId == value.projectId && value.pipelineVersion != draft?.baseVersionHash
        case (.configureCursor, .cursorEnvironmentChanged): true
        case (.pauseProject(let id), .settingsChanged(let change)):
            change.schedulerFlags?.contains(.projectPaused(id)) == true
        case (.resumeProject(let id), .settingsChanged(let change)):
            change.schedulerFlags.map { !$0.contains(.projectPaused(id)) } ?? false
        case (.setModelPoolRule, .settingsChanged(let change)), (.removeModelPoolRule, .settingsChanged(let change)):
            change.key == "model_pool"
        case (.refreshModelCatalog, .settingsChanged(let change)):
            change.key == "model_catalog"
        case (.clearModelFlag, .settingsChanged(let change)):
            change.key == "model_flag"
        case (_, .settingsChanged):
            mutationScope == .global || { if case .clearModelFlag = self { return true }; return false }()
        default: false
        }
    }

    var awaitsExternalCompletion: Bool {
        if case .restoreWIP = self { return true }
        return false
    }
}

public enum ClientCommandPhase: Equatable, Sendable {
    case sending
    case deliveryUncertain
    case awaitingEvent
    case awaitingEffect
    case applied
    case effectFailed(CommandError)
    case superseded
    case rejected(CommandError)
}
