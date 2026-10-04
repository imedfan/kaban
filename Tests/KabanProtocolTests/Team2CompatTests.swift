import Foundation
import XCTest
@testable import KabanProtocol

/// Wire-contract mutation tests: extra fields, omission/null, required fields and future enums.
/// No fixtures are recorded and no production DTO is changed.
final class Team2CompatTests: XCTestCase {
    private let encoder = KabanCoding.makeEncoder()
    private let decoder = KabanCoding.makeDecoder()
    private let at = Date(timeIntervalSince1970: 0)

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        try decoder.decode(type, from: JSONSerialization.data(withJSONObject: json))
    }
    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    /// Each field is classified independently; null and missing are both tested.
    private func audit<T: Codable & Equatable>(_ sample: T, fields: String, optional: String = "",
                                               defaults: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) throws {
        let known = Set(fields.split(separator: " ").map(String.init))
        let optionalKeys = Set(optional.split(separator: " ").map(String.init))
        let base = try object(sample)
        XCTAssertEqual(Set(base.keys).union(optionalKeys), known, String(describing: T.self), file: file, line: line)
        var extra = base; extra["team2FutureField"] = ["nested": ["arbitrary": true]]
        XCTAssertEqual(try decode(T.self, extra), sample, String(describing: T.self), file: file, line: line)
        for key in known {
            for null in [false, true] {
                var mutated = base
                if null { mutated[key] = NSNull() } else { mutated.removeValue(forKey: key) }
                let label = "\(T.self).\(key) \(null ? "null" : "missing")"
                if optionalKeys.contains(key) {
                    let back = try object(decode(T.self, mutated))
                    XCTAssertNil(back[key], label, file: file, line: line)
                } else if let expected = defaults[key] {
                    let back = try object(decode(T.self, mutated))
                    XCTAssertEqual(try canonical(XCTUnwrap(back[key])), try canonical(expected), label, file: file, line: line)
                } else {
                    XCTAssertThrowsError(try decode(T.self, mutated), label, file: file, line: line)
                }
            }
        }
    }

    func testPipelineDTOFieldContracts() throws {
        try audit(StageDisplay(icon: "x", color: "blue", order: 1), fields: "icon color order collapsed hidden", optional: "icon color")
        try audit(StageReturn(stage: "dev", limit: 3), fields: "stage limit")
        let policy = EffectiveGitPolicy(preset: .standard, allowed: [GitRule("status", source: .preset)],
            denied: [GitRule("reset", source: .project)], hardInvariants: HardInvariant.all,
            conditional: [ConditionalGitRule(returnReason: "returned", allowed: [GitRule("rebase", source: .stage)])],
            committer: .agentWithSafetyCommit, readOnly: false)
        try audit(policy, fields: "preset allowed denied hardInvariants conditional committer readOnly",
                  defaults: ["denied": [], "hardInvariants": [], "conditional": []])
        try audit(GitRule("rebase", source: .stage), fields: "rule source", optional: "source")
        try audit(ConditionalGitRule(returnReason: "returned", allowed: policy.allowed), fields: "returnReason allowed")
        let stage = StageSummary(id: "dev", name: "Dev", kind: .agent, display: StageDisplay(order: 1),
            wip: 3, model: "model", returnsTo: [StageReturn(stage: "dev", limit: 3)], onSuccess: "done", maxAttempts: 3,
            gates: ["test"], onFail: StageReturn(stage: "dev", limit: 3), onConflict: StageReturn(stage: "dev", limit: 2), gitPolicy: policy)
        try audit(stage, fields: "id name kind display wip model readOnly returnsTo onSuccess maxAttempts gates onFail onConflict gitPolicy",
                  optional: "wip model onSuccess maxAttempts onFail onConflict gitPolicy", defaults: ["gates": []])
        let pipeline = PipelineSummary(projectId: "p", versionHash: "hash", stages: [stage], defaultReturnStage: "dev",
                                       projectGitPolicy: policy, gitCommandCatalog: ["status"])
        try audit(pipeline, fields: "projectId versionHash gitPreset maxWaitingHuman maxRunsPerTask stages issues hasUncommittedEdits defaultReturnStage projectGitPolicy gitCommandCatalog",
                  optional: "versionHash defaultReturnStage projectGitPolicy", defaults: ["gitCommandCatalog": []])
        try audit(ValidationIssue(path: "stages[0]", stageId: "dev", code: "future", message: "m", severity: .warning, params: ["n": "1"]),
                  fields: "path stageId code message severity params", optional: "stageId", defaults: ["params": [String: String]()])
    }

    func testEntityDTOFieldContracts() throws {
        try audit(ProjectSummary(id: "p", name: "P", path: "/synthetic", maxRuns: 2, mascotSeed: "seed", openIncidentCount: 1,
                                 identity: GitIdentity(name: "Team2", email: "team2@example.com")),
                  fields: "id name path baseBranch availability weight maxRuns mascotSeed openIncidentCount identity",
                  optional: "maxRuns identity", defaults: ["openIncidentCount": 0])
        var card = Samples.tasks[0]; card.retryAt = at
        try audit(card, fields: "id projectId title stageId state priority branch attempt maxAttempts runsSinceHuman bounceByReason overlapsWith unusedGitGrants model retryAt suspiciousFiles hasAcceptanceCriteria updatedAt",
                  optional: "branch maxAttempts model retryAt", defaults: ["hasAcceptanceCriteria": false])
        let run = RunSummary(id: "r", taskId: "t", stageId: "dev", number: 1, status: .succeeded, endReason: .completed,
            requestedModel: "model", actualModelName: "Model", startedAt: at, endedAt: at, exitCode: 0, logPath: "/synthetic", wipRef: "refs/kaban/wip/r")
        try audit(run, fields: "id taskId stageId number status endReason requestedModel actualModelName countsTowardLimits startedAt endedAt exitCode logPath wipRef",
                  optional: "endReason actualModelName endedAt exitCode logPath wipRef")
        try audit(SuspiciousFile(path: "x", rule: .pattern, pattern: "x*", sizeBytes: 1, isText: true, blob: "blob"),
                  fields: "path rule pattern sizeBytes isText blob", optional: "pattern", defaults: ["isText": false])
        try audit(Incident(id: "i", projectId: "p", taskId: "t", runId: "r", kind: .refsMoved, rolledBack: [], openedAt: at, resolvedAt: at),
                  fields: "id projectId taskId runId kind rolledBack openedAt resolvedAt", optional: "runId resolvedAt")
        try audit(Samples.snapshot, fields: "protocolVersion seq projects pipelines tasks schedulerFlags modelFlags quota openIncidentCount stageLoad",
                  optional: "quota", defaults: ["stageLoad": []])
        try audit(StageLoad(projectId: "p", stageId: "dev", wipUsed: 1, wipLimit: 3),
                  fields: "projectId stageId wipUsed wipLimit", optional: "wipLimit")
    }

    func testCommandDTOFieldContracts() throws {
        try audit(FileBlobRef(path: "x", blob: "blob"), fields: "path blob")
        try audit(AcceptedFile(path: "x", blob: "blob", at: at, commandId: Samples.cmd), fields: "path blob by at commandId", optional: "commandId")
        try audit(QuotaOptions(enabled: true, consent: true), fields: "enabled consent pollInterval thresholdCm thresholdOm")
        try audit(McpServerRef(name: "server", source: .project), fields: "name source")
        try audit(CommandEnvelope(command: .pauseAll), fields: "protocolVersion commandId command")
        try audit(CommandReply(commandId: Samples.cmd, seq: 1, result: .ok), fields: "commandId seq result", optional: "seq")
        try audit(CommandError(code: "future", message: "m", params: ["x": "1"]), fields: "code message params", defaults: ["params": [String: String]()])
        try audit(GitIdentity(name: "Team2", email: "team2@example.com"), fields: "name email")
        try audit(EnvironmentReport(cursorAgentPath: "/synthetic", version: "1", authOK: true, gitVersion: "1", sandboxOK: true, notificationsAuthorized: true),
                  fields: "cursorAgentPath version authOK gitVersion sandboxOK notificationsAuthorized", optional: "cursorAgentPath version gitVersion")
        try audit(Samples.taskDetail, fields: "seq task feed runs humanRequests suspiciousFiles acceptedFiles clonePath", optional: "clonePath")
        try audit(FeedItem(id: "feed", at: at, kind: "future", text: "m", runId: "r"), fields: "id at kind text runId", optional: "runId")
    }

    func testEventPayloadFieldContracts() throws {
        try audit(EventEnvelope(seq: 1, at: at, projectId: "p", commandId: Samples.cmd, event: .settingsChanged(SettingsChange(key: "k", value: "v"))),
                  fields: "seq at projectId commandId event", optional: "projectId commandId")
        try audit(TaskTransition(taskId: "t", fromStage: "dev", toStage: "test", from: .running, to: .queued(nil), by: .daemon, runId: "r", note: "n"),
                  fields: "taskId fromStage toStage from to by runId note", optional: "runId note")
        try audit(SettingsChange(key: "k", value: "v"), fields: "key value")
        try audit(HumanRequest(requestId: "q", taskId: "t", runId: "r", question: "q"), fields: "requestId taskId runId question", optional: "runId")
        try audit(HumanAnswer(taskId: "t", requestId: "q", text: "a"), fields: "taskId requestId text", optional: "requestId")
        try audit(GitDenied(denialId: "d", taskId: "t", runId: "r", argv: ["git", "push"], rule: "push"), fields: "denialId taskId runId argv rule")
        try audit(GitGrantCreated(grantId: "g", denialId: "d", argv: [], by: .human), fields: "grantId denialId argv by")
        try audit(GitGrantDelivered(grantId: "g", runId: "r", via: .mcpResponse), fields: "grantId runId via")
        try audit(GitGrantRef(grantId: "g", runId: "r"), fields: "grantId runId")
        try audit(GitGrantRevoked(grantId: "g", by: .human), fields: "grantId by")
        try audit(GitGrantExpired(grantId: "g", reason: .taskDone), fields: "grantId reason")
        try audit(GitPolicyUpdated(projectId: "p", scope: .project, pipelineVersion: "hash"), fields: "projectId scope pipelineVersion")
        try audit(IncidentResolved(incidentId: "i", by: .human, commandId: Samples.cmd), fields: "incidentId by commandId", optional: "commandId")
        try audit(SuspiciousFilesFound(taskId: "t", runId: "r", stageId: "dev", files: []), fields: "taskId runId stageId files", optional: "runId")
        try audit(SuspiciousFilesAccepted(taskId: "t", files: [], by: .human, commandId: Samples.cmd), fields: "taskId files by commandId", optional: "commandId")
        try audit(RunnerCheck(ok: true, reason: .agentMissing, version: "1", checkedAt: at), fields: "ok reason version checkedAt", optional: "reason version")
        try audit(PipelineDraftValidation(projectId: "p", contentHash: "hash", issues: [], resolved: Samples.pipeline),
                  fields: "projectId contentHash issues resolved", optional: "resolved")
        try audit(RunProgress(runId: "r", taskId: "t", message: "m", lastActivityAt: at), fields: "runId taskId message lastActivityAt", optional: "message")
    }

    func testModelQuotaAndLogFieldContracts() throws {
        try audit(ModelInfo(id: "model", name: "Model", pool: .cm, missingSince: at), fields: "id name pool needsReview forbidden missingSince", optional: "missingSince")
        try audit(ModelPoolRule(pattern: "model*", pool: .cm, source: .user), fields: "pattern pool source")
        try audit(ModelFlag(modelId: "model", reason: .substituted, requested: "Model", actual: "Other", fallbackModel: "other", since: at, lastProbeAt: at),
                  fields: "modelId reason requested actual fallbackModel since lastProbeAt", optional: "actual fallbackModel lastProbeAt")
        try audit(QuotaState(cm: 1, om: 2, billingCycleStart: at, billingCycleEnd: at, fetchedAt: at),
                  fields: "cm om billingCycleStart billingCycleEnd fetchedAt", optional: "cm om billingCycleStart billingCycleEnd")
        try audit(LogBatch(runId: "r", fromOffset: 0, nextOffset: 1, events: [.message(role: "assistant", text: "m")]), fields: "runId fromOffset nextOffset events")
    }

    private func futureRaw<T: Codable>(_ type: T.Type, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decoder.decode(type, from: Data(#""team2_future""#.utf8)), String(describing: type), file: file, line: line)
    }
    func testUnknownRawEnumsRejectRatherThanGuess() {
        futureRaw(StageKind.self); futureRaw(GitPreset.self); futureRaw(StageCommitter.self); futureRaw(GitRuleSource.self)
        futureRaw(ValidationIssue.Severity.self); futureRaw(ProjectSummary.Availability.self); futureRaw(SuspiciousFile.Rule.self)
        futureRaw(IncidentKind.self); futureRaw(IncidentListState.self); futureRaw(McpServerRef.Source.self)
        futureRaw(GitGrantDeliveryVia.self); futureRaw(GitGrantExpiryReason.self); futureRaw(Actor.self)
        futureRaw(ModelPool.self); futureRaw(ModelPoolRule.Source.self); futureRaw(ModelFlag.Reason.self)
        futureRaw(SchedulerFlag.Level.self); futureRaw(RunnerUnavailableReason.self); futureRaw(ProjectUnavailableReason.self)
        futureRaw(TaskStatus.self); futureRaw(WaitingHumanReason.self); futureRaw(QueuedReason.self); futureRaw(RetryWaitReason.self)
        futureRaw(BlockedReason.self); futureRaw(RunStatus.self); futureRaw(RunEndReason.self)
    }

    private func extra<T: Codable & Equatable>(_ value: T) throws {
        var wire = try object(value); wire["team2FutureField"] = 1
        XCTAssertEqual(try decode(T.self, wire), value)
    }
    func testTaggedEnumsKnownAndUnknownData() throws {
        for value in Samples.events { try extra(value.event) }
        for value in Samples.ephemeral { try extra(value) }
        XCTAssertEqual(try decode(JournalEvent.self, ["type": "future", "data": ["unexpected": true]]), .unknown(type: "future"))
        XCTAssertEqual(try decode(EphemeralEvent.self, ["type": "future", "data": NSNull()]), .unknown(type: "future"))
        XCTAssertThrowsError(try decode(JournalEvent.self, ["type": "taskCreated"]))
        XCTAssertThrowsError(try decode(EphemeralEvent.self, ["type": "quotaUpdated"]))
        try extra(PolicyScope.stage("dev")); try extra(TaskState.retryWait(.crash))
        for value in Samples.flags { try extra(value) }
        XCTAssertThrowsError(try decode(PolicyScope.self, ["kind": "future"]))
        XCTAssertThrowsError(try decode(TaskState.self, ["status": "future"]))
        XCTAssertThrowsError(try decode(TaskState.self, ["status": "waiting_human", "reason": "future"]))
        XCTAssertThrowsError(try decode(TaskState.self, ["status": "queued", "reason": "future"]))
        XCTAssertThrowsError(try decode(SchedulerFlag.self, ["level": "mac", "flag": "future"]))
        XCTAssertThrowsError(try decode(SchedulerFlag.self, ["level": "project", "flag": "unavailable", "projectId": "p", "reason": "future"]))
        XCTAssertNil(try decode(GitRule.self, ["rule": "status", "source": "future"]).source)
        XCTAssertThrowsError(try decode(GitRule.self, ["rule": "status", "source": 123]))
    }

    private func unknownCase<T: Codable>(_ type: T.Type) {
        XCTAssertThrowsError(try decode(type, ["team2FutureCase": [:]]), String(describing: type))
    }
    func testSynthesizedEnumsIgnoreFieldsButRejectFutureCases() throws {
        for value in Samples.commands { try extra(value.command) }
        try extra(CommandResult.error(CommandError(code: "future", message: "m")))
        try extra(AgentEvent.initialized(modelName: "Model", sessionId: "s"))
        try extra(RejectTarget.stage(stageId: "dev")); try extra(RecheckScope.project(projectId: "p"))
        unknownCase(Command.self); unknownCase(CommandResult.self); unknownCase(AgentEvent.self)
        unknownCase(RejectTarget.self); unknownCase(RecheckScope.self)
        XCTAssertEqual(try decode(Command.self, ["addProject": ["path": "/synthetic", "createTemplate": true]]),
                       .addProject(path: "/synthetic", createTemplate: true, identity: nil))
        XCTAssertEqual(try decode(AgentEvent.self, ["initialized": [:]]), .initialized(modelName: nil, sessionId: nil))
        XCTAssertThrowsError(try decode(Command.self, ["cancelTask": ["taskId": "t"]]))
    }

    private func payload<T: Codable & Equatable>(_ value: T, optional: Set<String> = []) throws {
        let base = try object(value), tag = try XCTUnwrap(base.keys.first)
        let data = try XCTUnwrap(base[tag] as? [String: Any])
        var fields = data; fields["team2FutureField"] = ["nested": true]
        XCTAssertEqual(try decode(T.self, [tag: fields]), value)
        for key in data.keys {
            var fields = data; fields.removeValue(forKey: key)
            if optional.contains(key) {
                let decoded = try object(decode(T.self, [tag: fields]))
                XCTAssertNil((decoded[tag] as? [String: Any])?[key], "\(T.self).\(tag).\(key)")
            } else { XCTAssertThrowsError(try decode(T.self, [tag: fields]), "\(T.self).\(tag).\(key)") }
        }
    }
    func testEveryCommandPayloadAndOptionalAssociatedValues() throws {
        let values: [Command] = [
            .addProject(path: "/synthetic", createTemplate: true, identity: GitIdentity(name: "T", email: "t@example.com")),
            .setProjectIdentity(projectId: "p", identity: GitIdentity(name: "T", email: "t@example.com")),
            .removeProject(projectId: "p"), .relinkProject(projectId: "p", path: "/synthetic"), .listBranches(projectId: "p"),
            .detectGates(projectId: "p"), .setMascot(projectId: "p", seed: "s"), .setProjectWeight(projectId: "p", weight: 1, maxRuns: 2),
            .updatePipeline(projectId: "p", contentHash: "h"), .validatePipeline(projectId: "p", content: "x"), .getTaskDetail(taskId: "t"),
            .createTask(projectId: "p", title: "t", body: "b"), .editTask(taskId: "t", title: "t", body: "b"), .setPriority(taskId: "t", priority: 1),
            .moveTask(taskId: "t", stage: "dev"), .pauseTask(taskId: "t"), .resumeTask(taskId: "t"), .cancelTask(taskId: "t", keepBranch: true),
            .retryStage(taskId: "t", grantAttempts: 1), .setModelOverride(taskId: "t", stageId: "dev", model: "model"),
            .answerHuman(taskId: "t", text: "a", requestId: "q"), .approve(taskId: "t"), .requestChanges(taskId: "t", comments: "c", target: "dev"),
            .reject(taskId: "t", target: .cancel, keepBranch: true), .acceptSuspiciousFiles(taskId: "t", files: []),
            .allowGitOnce(denialId: "d"), .addDenialToPolicy(denialId: "d", scope: .project), .revokeGitGrant(grantId: "g"),
            .pauseAll, .resumeAll, .pauseProject(projectId: "p"), .resumeProject(projectId: "p"), .resumeAfterRateLimit,
            .setMaxConcurrentRuns(count: 1), .checkEnvironment, .recheck(scope: .runner), .listModels, .refreshModelCatalog,
            .setModelPoolRule(pattern: "model*", pool: .cm), .removeModelPoolRule(pattern: "model*"), .clearModelFlag(modelId: "model"),
            .setQuotaOptions(options: QuotaOptions(enabled: false, consent: false)), .listProjectMcpServers(projectId: "p"),
            .setProjectMcpAllowlist(projectId: "p", servers: []), .getRunHistory(taskId: "t"), .listIncidents(projectIds: ["p"], state: .all)
        ]
        XCTAssertEqual(values.count, 46)
        for value in values { try extra(value); try payload(value, optional: ["identity", "maxRuns", "title", "body", "grantAttempts", "model", "requestId", "target", "projectIds"].filter { key in
            // title/body are optional only for editTask; target only for requestChanges.
            if key == "title" || key == "body" { if case .editTask = value { return true }; return false }
            if key == "target" { if case .requestChanges = value { return true }; return false }
            if key == "identity" { if case .addProject = value { return true }; return false }
            return true
        }.reduce(into: Set<String>()) { $0.insert($1) }) }
        try payload(AgentEvent.usage(inputTokens: 1, outputTokens: 2), optional: ["inputTokens", "outputTokens"])
        try payload(AgentEvent.error(code: "x", message: "m"), optional: ["code"])
        try payload(AgentEvent.result(ok: true, durationMs: 1), optional: ["durationMs"])
        try payload(AgentEvent.initialized(modelName: "Model", sessionId: "s"), optional: ["modelName", "sessionId"])
        try payload(AgentEvent.message(role: "assistant", text: "m"))
        try payload(AgentEvent.toolCall(id: "c", name: "tool", summary: "s"))
        try payload(AgentEvent.toolResult(id: "c", ok: true, summary: "s"))
    }

    private func stringID<T: KabanID>(_ type: T.Type) throws {
        XCTAssertEqual(try decoder.decode(type, from: Data(#""future-id""#.utf8)).rawValue, "future-id")
        XCTAssertThrowsError(try decode(type, ["rawValue": "future-id", "team2FutureField": true]))
    }
    func testIdentifiersStaySingleValueAndVersionsAreTransportOwned() throws {
        try stringID(ProjectID.self); try stringID(TaskID.self); try stringID(RunID.self); try stringID(StageID.self)
        try stringID(ModelID.self); try stringID(IncidentID.self); try stringID(DenialID.self); try stringID(GrantID.self); try stringID(HumanRequestID.self)
        var snapshot = try object(Samples.snapshot); snapshot["protocolVersion"] = 999
        XCTAssertEqual(try decode(Snapshot.self, snapshot).protocolVersion, 999)
        var envelope = try object(CommandEnvelope(command: .pauseAll)); envelope["protocolVersion"] = 999
        XCTAssertEqual(try decode(CommandEnvelope.self, envelope).protocolVersion, 999)
        XCTAssertThrowsError(try decoder.decode(CommandID.self, from: Data(#""not-a-uuid""#.utf8)))
        XCTAssertThrowsError(try decoder.decode(Seq.self, from: Data(#""not-a-number""#.utf8)))
    }
}
