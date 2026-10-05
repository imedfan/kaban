import Foundation

/// Stable wire names. The exhaustive switch forces new commands to join capability reporting.
public enum CommandName: String, Codable, Hashable, Sendable, CaseIterable {
    case addProject
    case setProjectIdentity
    case removeProject
    case relinkProject
    case listBranches
    case detectGates
    case setMascot
    case setProjectWeight
    case updatePipeline
    case validatePipeline
    case validatePipelineDraft
    case getTaskDetail
    case createTask
    case editTask
    case setPriority
    case moveTask
    case pauseTask
    case resumeTask
    case cancelTask
    case retryStage
    case setModelOverride
    case restoreWIP
    case answerHuman
    case approve
    case requestChanges
    case reject
    case acceptSuspiciousFiles
    case allowGitOnce
    case addDenialToPolicy
    case revokeGitGrant
    case pauseAll
    case resumeAll
    case pauseProject
    case resumeProject
    case resumeAfterRateLimit
    case setMaxConcurrentRuns
    case checkEnvironment
    case getCursorEnvironment
    case configureCursor
    case recheck
    case listModels
    case refreshModelCatalog
    case setModelPoolRule
    case removeModelPoolRule
    case clearModelFlag
    case setQuotaOptions
    case listProjectMcpServers
    case setProjectMcpAllowlist
    case getRunHistory
    case listIncidents
}

extension Command {
    public var name: CommandName {
        switch self {
        case .addProject: .addProject
        case .setProjectIdentity: .setProjectIdentity
        case .removeProject: .removeProject
        case .relinkProject: .relinkProject
        case .listBranches: .listBranches
        case .detectGates: .detectGates
        case .setMascot: .setMascot
        case .setProjectWeight: .setProjectWeight
        case .updatePipeline: .updatePipeline
        case .validatePipeline: .validatePipeline
        case .validatePipelineDraft: .validatePipelineDraft
        case .getTaskDetail: .getTaskDetail
        case .createTask: .createTask
        case .editTask: .editTask
        case .setPriority: .setPriority
        case .moveTask: .moveTask
        case .pauseTask: .pauseTask
        case .resumeTask: .resumeTask
        case .cancelTask: .cancelTask
        case .retryStage: .retryStage
        case .setModelOverride: .setModelOverride
        case .restoreWIP: .restoreWIP
        case .answerHuman: .answerHuman
        case .approve: .approve
        case .requestChanges: .requestChanges
        case .reject: .reject
        case .acceptSuspiciousFiles: .acceptSuspiciousFiles
        case .allowGitOnce: .allowGitOnce
        case .addDenialToPolicy: .addDenialToPolicy
        case .revokeGitGrant: .revokeGitGrant
        case .pauseAll: .pauseAll
        case .resumeAll: .resumeAll
        case .pauseProject: .pauseProject
        case .resumeProject: .resumeProject
        case .resumeAfterRateLimit: .resumeAfterRateLimit
        case .setMaxConcurrentRuns: .setMaxConcurrentRuns
        case .checkEnvironment: .checkEnvironment
        case .getCursorEnvironment: .getCursorEnvironment
        case .configureCursor: .configureCursor
        case .recheck: .recheck
        case .listModels: .listModels
        case .refreshModelCatalog: .refreshModelCatalog
        case .setModelPoolRule: .setModelPoolRule
        case .removeModelPoolRule: .removeModelPoolRule
        case .clearModelFlag: .clearModelFlag
        case .setQuotaOptions: .setQuotaOptions
        case .listProjectMcpServers: .listProjectMcpServers
        case .setProjectMcpAllowlist: .setProjectMcpAllowlist
        case .getRunHistory: .getRunHistory
        case .listIncidents: .listIncidents
        }
    }
}

/// Managed fake commands have a functioning durable boundary, but do not operate real repos/runs.
public enum CommandSupport: String, Codable, Hashable, Sendable { case supported, managedFakeOnly, unsupported }
public struct CommandCapability: Codable, Hashable, Sendable {
    /// String preserves entries added by a newer daemon.
    public var name: String
    public var support: CommandSupport
    public init(name: String, support: CommandSupport) { self.name = name; self.support = support }
}
public struct OperationCapability: Codable, Hashable, Sendable {
    public var name: String
    public var supported: Bool
    public init(name: String, supported: Bool) { self.name = name; self.supported = supported }
}
public struct DaemonCapabilities: Codable, Hashable, Sendable {
    public var operations: [OperationCapability]
    public var commands: [CommandCapability]
    public init(operations: [OperationCapability], commands: [CommandCapability]) {
        self.operations = operations; self.commands = commands
    }
}
