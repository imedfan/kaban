import Foundation
import XCTest
@testable import KabanProtocol

final class Team2ReferenceSamplesTests: XCTestCase {
    func testEveryReferenceSampleRoundTrips() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reference-samples", withExtension: "json", subdirectory: "Fixtures/team2"))
        let samples = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let decoder = KabanCoding.makeDecoder()
        var checked = Set<String>()
        func check<T: Codable & Equatable>(_ type: T.Type, _ key: String) throws {
            let sample = try XCTUnwrap(samples[key], key)
            let data = try JSONSerialization.data(withJSONObject: sample, options: [.fragmentsAllowed])
            let value = try decoder.decode(type, from: data)
            let encoded = try KabanCoding.makeEncoder().encode(value)
            XCTAssertEqual(try decoder.decode(type, from: encoded), value, key)
            checked.insert(key)
        }
        try check(ProjectSummary.self, "ProjectSummary")
        try check(TaskCard.self, "TaskCard")
        try check(RunSummary.self, "RunSummary")
        try check(SuspiciousFile.self, "SuspiciousFile")
        try check(Incident.self, "Incident")
        try check(Snapshot.self, "Snapshot")
        try check(StageLoad.self, "StageLoad")
        try check(QuotaState.self, "QuotaState")
        try check(LogBatch.self, "LogBatch")
        try check(StageDisplay.self, "StageDisplay")
        try check(StageReturn.self, "StageReturn")
        try check(StageSummary.self, "StageSummary")
        try check(GitRule.self, "GitRule")
        try check(EffectiveGitPolicy.self, "EffectiveGitPolicy")
        try check(ConditionalGitRule.self, "ConditionalGitRule")
        try check(PipelineSummary.self, "PipelineSummary")
        try check(ValidationIssue.self, "ValidationIssue")
        try check(FileBlobRef.self, "FileBlobRef")
        try check(AcceptedFile.self, "AcceptedFile")
        try check(QuotaOptions.self, "QuotaOptions")
        try check(McpServerRef.self, "McpServerRef")
        try check(CommandEnvelope.self, "CommandEnvelope")
        try check(CommandReply.self, "CommandReply")
        try check(CommandError.self, "CommandError")
        try check(GitIdentity.self, "GitIdentity")
        try check(EnvironmentReport.self, "EnvironmentReport")
        try check(TaskDetail.self, "TaskDetail")
        try check(FeedItem.self, "FeedItem")
        try check(ProjectID.self, "ProjectID")
        try check(TaskID.self, "TaskID")
        try check(RunID.self, "RunID")
        try check(StageID.self, "StageID")
        try check(ModelID.self, "ModelID")
        try check(IncidentID.self, "IncidentID")
        try check(DenialID.self, "DenialID")
        try check(GrantID.self, "GrantID")
        try check(HumanRequestID.self, "HumanRequestID")
        try check(ModelInfo.self, "ModelInfo")
        try check(ModelPoolRule.self, "ModelPoolRule")
        try check(ModelFlag.self, "ModelFlag")
        try check(EventEnvelope.self, "EventEnvelope")
        try check(TaskTransition.self, "TaskTransition")
        try check(SettingsChange.self, "SettingsChange")
        try check(HumanRequest.self, "HumanRequest")
        try check(HumanAnswer.self, "HumanAnswer")
        try check(GitDenied.self, "GitDenied")
        try check(GitGrantCreated.self, "GitGrantCreated")
        try check(GitGrantDelivered.self, "GitGrantDelivered")
        try check(GitGrantRef.self, "GitGrantRef")
        try check(GitGrantRevoked.self, "GitGrantRevoked")
        try check(GitGrantExpired.self, "GitGrantExpired")
        try check(GitPolicyUpdated.self, "GitPolicyUpdated")
        try check(IncidentResolved.self, "IncidentResolved")
        try check(SuspiciousFilesFound.self, "SuspiciousFilesFound")
        try check(SuspiciousFilesAccepted.self, "SuspiciousFilesAccepted")
        try check(RunnerCheck.self, "RunnerCheck")
        try check(PipelineDraftValidation.self, "PipelineDraftValidation")
        try check(RunProgress.self, "RunProgress")
        try check(IncidentKind.self, "IncidentKind")
        try check(TaskStatus.self, "TaskStatus")
        try check(WaitingHumanReason.self, "WaitingHumanReason")
        try check(QueuedReason.self, "QueuedReason")
        try check(RetryWaitReason.self, "RetryWaitReason")
        try check(BlockedReason.self, "BlockedReason")
        try check(RunStatus.self, "RunStatus")
        try check(RunEndReason.self, "RunEndReason")
        try check(StageKind.self, "StageKind")
        try check(GitPreset.self, "GitPreset")
        try check(StageCommitter.self, "StageCommitter")
        try check(GitRuleSource.self, "GitRuleSource")
        try check(IncidentListState.self, "IncidentListState")
        try check(GitGrantDeliveryVia.self, "GitGrantDeliveryVia")
        try check(GitGrantExpiryReason.self, "GitGrantExpiryReason")
        try check(Actor.self, "Actor")
        try check(ModelPool.self, "ModelPool")
        try check(RunnerUnavailableReason.self, "RunnerUnavailableReason")
        try check(ProjectUnavailableReason.self, "ProjectUnavailableReason")
        try check(ValidationIssue.Severity.self, "ValidationIssue.Severity")
        try check(ProjectSummary.Availability.self, "ProjectSummary.Availability")
        try check(SuspiciousFile.Rule.self, "SuspiciousFile.Rule")
        try check(McpServerRef.Source.self, "McpServerRef.Source")
        try check(ModelPoolRule.Source.self, "ModelPoolRule.Source")
        try check(ModelFlag.Reason.self, "ModelFlag.Reason")
        try check(SchedulerFlag.Level.self, "SchedulerFlag.Level")
        try check(TaskState.self, "TaskState")
        try check(SchedulerFlag.self, "SchedulerFlag")
        try check(PolicyScope.self, "PolicyScope")
        try check(RejectTarget.self, "RejectTarget")
        try check(RecheckScope.self, "RecheckScope")
        try check(Command.self, "Command")
        try check(AgentEvent.self, "AgentEvent")
        try check(JournalEvent.self, "JournalEvent")
        try check(EphemeralEvent.self, "EphemeralEvent")
        try check(CommandResult.self, "CommandResult")
        try check(CommandID.self, "CommandID")
        try check(Seq.self, "Seq")
        for name in [
            "addProject", "setProjectIdentity", "removeProject", "relinkProject",
            "listBranches", "detectGates", "setMascot", "setProjectWeight",
            "updatePipeline", "validatePipeline", "getTaskDetail", "createTask",
            "editTask", "setPriority", "moveTask", "pauseTask",
            "resumeTask", "cancelTask", "retryStage", "setModelOverride",
            "answerHuman", "approve", "requestChanges", "reject",
            "acceptSuspiciousFiles", "allowGitOnce", "addDenialToPolicy", "revokeGitGrant",
            "pauseAll", "resumeAll", "pauseProject", "resumeProject",
            "resumeAfterRateLimit", "setMaxConcurrentRuns", "checkEnvironment", "recheck",
            "listModels", "refreshModelCatalog", "setModelPoolRule", "removeModelPoolRule",
            "clearModelFlag", "setQuotaOptions", "listProjectMcpServers", "setProjectMcpAllowlist",
            "getRunHistory", "listIncidents"
        ] {
            try check(Command.self, "command.\(name)")
        }
        for name in [
            "taskCreated", "taskUpdated", "taskTransitioned", "taskEdited",
            "projectAdded", "projectUpdated", "projectRemoved", "pipelineApplied",
            "settingsChanged", "humanRequested", "humanAnswered", "gitDenied",
            "gitGrantCreated", "gitGrantDelivered", "gitGrantConsumed", "gitGrantRevoked",
            "gitGrantExpired", "gitPolicyUpdated", "incidentOpened", "incidentResolved",
            "suspiciousFilesFound", "suspiciousFilesAccepted", "stageLoadChanged", "unknown"
        ] {
            try check(JournalEvent.self, "JournalEvent.\(name)")
        }
        for name in [
            "schedulerFlagsChanged", "modelFlagsChanged", "quotaUpdated", "modelCatalogChanged",
            "runnerChecked", "pipelineDraftValidated", "runProgress", "resyncRequired",
            "unknown"
        ] {
            try check(EphemeralEvent.self, "EphemeralEvent.\(name)")
        }
        XCTAssertEqual(checked.count, 175)
        XCTAssertEqual(checked, Set(samples.keys), "unverified or undocumented fixture")
    }
}
