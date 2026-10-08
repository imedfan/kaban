import Foundation
import XCTest
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class GitGrantTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testGrantIsSingleUseAndDoesNotWidenOrOverrideHardRules() throws {
        let f = try fixture(pipeline(preset: "standard"))
        let run = try launch(f, "once")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "once", at: at)
        let denied = try check(server, token, ["git", "rebase", "feature"])
        XCTAssertFalse(denied.allow)
        XCTAssertEqual(denied.message, GitCheck.deniedMessage)
        let detail = try f.store.getTaskDetail("once")
        let denial = try XCTUnwrap(detail.gitDenials.first)
        XCTAssertEqual(denial.denial.argv, ["git", "rebase", "feature"])
        let first = try f.store.execute(.init(command: .allowGitOnce(denialId: denial.denial.denialId)), now: { self.at })
        let second = try f.store.execute(.init(command: .allowGitOnce(denialId: denial.denial.denialId)), now: { self.at })
        XCTAssertEqual(first.result, .ok)
        XCTAssertEqual(second.result, .ok)
        let granted = try f.store.getTaskDetail("once")
        XCTAssertEqual(granted.gitGrants.count, 1)
        XCTAssertEqual(granted.gitGrants[0].grant.argv, ["git", "rebase", "feature"])
        XCTAssertNil(granted.gitGrants[0].consumption)
        XCTAssertEqual(granted.task.unusedGitGrants, 1)
        XCTAssertEqual(try f.store.getSnapshot().tasks.first { $0.id == "once" }?.unusedGitGrants, 1)
        let narrower = try check(server, token, ["rebase"])
        XCTAssertFalse(narrower.allow)
        XCTAssertEqual(try f.store.getTaskDetail("once").gitGrants[0].grant.argv, ["git", "rebase", "feature"])
        let spent = try check(server, token, ["git", "rebase", "feature"])
        XCTAssertTrue(spent.allow)
        XCTAssertEqual(spent.rule, "grant")
        let again = try check(server, token, ["git", "rebase", "feature"])
        XCTAssertFalse(again.allow)
        XCTAssertEqual(try f.store.getTaskDetail("once").gitGrants.filter { $0.consumption != nil }.count, 1)
        XCTAssertEqual(try f.store.getTaskDetail("once").task.unusedGitGrants, 0)
        XCTAssertTrue(try f.store.events(after: 0).contains {
            if case .taskUpdated(let card) = $0.event { return card.id == "once" && card.unusedGitGrants == 1 }; return false
        })
        let foreign = try check(server, token, ["git", "fetch", "origin", "main"])
        XCTAssertFalse(foreign.allow)
        XCTAssertEqual(foreign.rule, "foreign_refs")
        XCTAssertEqual(try task(f, "once").machine.state, .running)
        XCTAssertEqual(try task(f, "once").machine.attemptsUsed, 0)
        _ = run

        // Hard-invariant denials count toward the five-denial stop, so they run on a fresh task.
        _ = try launch(f, "hard")
        let hardToken = try f.store.issueRunToken(taskId: "hard", at: at)
        let pushed = try check(server, hardToken, ["git", "push", "origin", "main"])
        XCTAssertFalse(pushed.allow)
        XCTAssertEqual(pushed.rule, "push")
        let pushDenial = try XCTUnwrap(try f.store.getTaskDetail("hard").gitDenials.last)
        XCTAssertEqual(code(try f.store.execute(.init(command: .allowGitOnce(denialId: pushDenial.denial.denialId)), now: { self.at })), "git_hard_invariant")
        try f.store.queueGitGrantNotice(taskId: "hard", argv: ["push", "origin", "main"], at: at)
        let planted = try check(server, hardToken, ["push", "origin", "main"])
        XCTAssertFalse(planted.allow)
        XCTAssertEqual(planted.rule, "push")
        XCTAssertTrue(try f.store.getTaskDetail("hard").gitGrants.filter { $0.grant.argv == ["push", "origin", "main"] }.allSatisfy { $0.consumption == nil })
        let escaped = try check(server, hardToken, ["git", "-C", "/elsewhere", "status"])
        XCTAssertFalse(escaped.allow)
        XCTAssertEqual(escaped.rule, "config")
        let kaban = try check(server, hardToken, ["git", "add", ".kaban/pipeline.yaml"])
        XCTAssertFalse(kaban.allow)
        XCTAssertEqual(kaban.rule, "kaban_dir")
        XCTAssertEqual(try task(f, "hard").machine.state, .running)
        XCTAssertEqual(try task(f, "hard").machine.attemptsUsed, 0)
    }

    func testCompletedTaskDenialCannotCreateANewGrant() throws {
        let f = try fixture(pipeline(preset: "standard"))
        _ = try launch(f, "closed")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "closed", at: at)
        _ = try check(server, token, ["git", "rebase", "feature"])
        let denial = try XCTUnwrap(try f.store.getTaskDetail("closed").gitDenials.first)
        XCTAssertEqual(try f.store.execute(.init(command: .cancelTask(taskId: "closed", keepBranch: false)), now: { self.at }).result, .ok)
        let reply = try f.store.execute(.init(command: .allowGitOnce(denialId: denial.denial.denialId)), now: { self.at })
        XCTAssertEqual(code(reply), "stale_git_denial")
        XCTAssertTrue(try f.store.getTaskDetail("closed").gitGrants.isEmpty)
    }

    func testDenialFromPreviousStageCannotAuthorizeCurrentStage() throws {
        let f = try fixture(pipeline(preset: "standard"))
        _ = try launch(f, "moved")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "moved", at: at)
        _ = try check(server, token, ["git", "rebase", "feature"])
        let denial = try XCTUnwrap(try f.store.getTaskDetail("moved").gitDenials.first)
        _ = try prepare(f, "moved")
        _ = try apply(f, "moved", .completeStage(try runId(f, "moved"), summary: "dev"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(try task(f, "moved").machine.stageId, "test")
        let reply = try f.store.execute(.init(command: .allowGitOnce(denialId: denial.denial.denialId)), now: { self.at })
        XCTAssertEqual(code(reply), "stale_git_denial")
        XCTAssertTrue(try f.store.getTaskDetail("moved").gitGrants.isEmpty)
    }

    func testConsumedGrantCannotBeRevoked() throws {
        let f = try fixture(pipeline(preset: "standard"))
        _ = try launch(f, "spent")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "spent", at: at)
        _ = try check(server, token, ["git", "rebase", "feature"])
        let denial = try XCTUnwrap(try f.store.getTaskDetail("spent").gitDenials.first)
        _ = try f.store.execute(.init(command: .allowGitOnce(denialId: denial.denial.denialId)), now: { self.at })
        XCTAssertTrue(try check(server, token, ["git", "rebase", "feature"]).allow)
        let grant = try XCTUnwrap(try f.store.getTaskDetail("spent").gitGrants.first)
        let reply = try f.store.execute(.init(command: .revokeGitGrant(grantId: grant.grant.grantId)), now: { self.at })
        XCTAssertEqual(code(reply), "git_grant_inactive")
        XCTAssertNil(try f.store.getTaskDetail("spent").gitGrants.first?.revocation)
    }

    func testConsumedAndRevokedGrantsKeepTheirTerminalOutcomeOnCancellation() throws {
        let f = try fixture(pipeline(preset: "standard"))
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let ids: [TaskID] = ["spent", "revoked"]
        for id in ids {
            _ = try launch(f, id)
            let token = try f.store.issueRunToken(taskId: id, at: at)
            _ = try check(server, token, ["git", "rebase", "feature"])
            let denial = try XCTUnwrap(try f.store.getTaskDetail(id).gitDenials.first)
            _ = try f.store.execute(.init(command: .allowGitOnce(denialId: denial.denial.denialId)), now: { self.at })
            let grant = try XCTUnwrap(try f.store.getTaskDetail(id).gitGrants.first)
            if id == "spent" { XCTAssertTrue(try check(server, token, ["git", "rebase", "feature"]).allow) }
            else { _ = try f.store.execute(.init(command: .revokeGitGrant(grantId: grant.grant.grantId)), now: { self.at }) }
            _ = try f.store.execute(.init(command: .cancelTask(taskId: id, keepBranch: false)), now: { self.at })
            let ended = try XCTUnwrap(try f.store.getTaskDetail(id).gitGrants.first)
            XCTAssertNil(ended.expiry)
            XCTAssertEqual(ended.consumption != nil, id == "spent")
            XCTAssertEqual(ended.revocation != nil, id == "revoked")
        }
    }

    func testConditionalOverrideIsCheckedByTheServer() throws {
        let f = try fixture(pipeline(preset: "strict", conditional: true))
        _ = try launch(f, "cond")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "cond", at: at)
        let policy = try resolved(f, "cond", stage: "dev")
        XCTAssertFalse(policy.allowed.contains { $0.rule == "commit" })
        XCTAssertTrue(policy.conditional.contains { $0.returnReason == "returned" && $0.allowed.contains { $0.rule == "commit" } })
        let before = try check(server, token, ["git", "commit", "-m", "later"])
        XCTAssertFalse(before.allow)
        XCTAssertNil(try f.store.getTaskDetail("cond").gitGrants.first)
        _ = try prepare(f, "cond")
        _ = try apply(f, "cond", .completeStage(try runId(f, "cond"), summary: "dev"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(try task(f, "cond").machine.stageId.rawValue, "test")
        _ = try apply(f, "cond", .start(RunID(rawValue: "test-run")))
        _ = try apply(f, "cond", .returnToStage(try runId(f, "cond"), target: "dev", issues: ["needs a commit"]))
        _ = try apply(f, "cond", .start(RunID(rawValue: "dev-again")))
        XCTAssertEqual(try task(f, "cond").machine.returnReason, .returned)
        let again = try f.store.issueRunToken(taskId: "cond", at: at)
        let allowed = try check(server, again, ["git", "commit", "-m", "later"])
        XCTAssertTrue(allowed.allow)
        XCTAssertEqual(allowed.rule, "policy")
        XCTAssertNil(try f.store.getTaskDetail("cond").gitGrants.first?.consumption)
        let still = try resolved(f, "cond", stage: "dev")
        XCTAssertFalse(still.allowed.contains { $0.rule == "commit" })
        XCTAssertTrue(still.conditional.contains { $0.returnReason == "returned" && $0.allowed.contains { $0.rule == "commit" } })
    }

    func testDeliveryAndConsumptionRemainDistinctAfterCancellation() throws {
        let f = try fixture(pipeline(preset: "standard"))
        _ = try launch(f, "note")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "note", at: at)
        let unknown = try check(server, token, ["git", "frobnicate", "--weird", "keep-me"])
        XCTAssertFalse(unknown.allow)
        XCTAssertEqual(unknown.rule, "unknown")
        XCTAssertEqual(try f.store.getTaskDetail("note").gitDenials.map(\.denial.argv), [["git", "frobnicate", "--weird", "keep-me"]])
        let denied = try check(server, token, ["git", "rebase", "feature"])
        XCTAssertFalse(denied.allow)
        let denial = try XCTUnwrap(try f.store.getTaskDetail("note").gitDenials.last)
        XCTAssertEqual(try f.store.execute(.init(command: .allowGitOnce(denialId: denial.denial.denialId)), now: { self.at }).result, .ok)
        var grant = try XCTUnwrap(try f.store.getTaskDetail("note").gitGrants.first)
        XCTAssertNil(grant.delivery)
        XCTAssertNil(grant.consumption)
        let context = try server.roundTrip(token: token, method: "tools/call", params: ["name": "get_task_context", "arguments": [:]])
        XCTAssertEqual(context.status, 200)
        grant = try XCTUnwrap(try f.store.getTaskDetail("note").gitGrants.first)
        XCTAssertNotNil(grant.delivery)
        XCTAssertNil(grant.consumption)
        XCTAssertEqual(grant.grant.argv, ["git", "rebase", "feature"])
        let used = try check(server, token, ["git", "rebase", "feature"])
        XCTAssertTrue(used.allow)
        grant = try XCTUnwrap(try f.store.getTaskDetail("note").gitGrants.first)
        XCTAssertNotNil(grant.delivery)
        XCTAssertNotNil(grant.consumption)
        let revoked = try f.store.execute(.init(command: .revokeGitGrant(grantId: grant.grant.grantId)), now: { self.at })
        XCTAssertEqual(code(revoked), "git_grant_inactive")
        XCTAssertNil(try f.store.getTaskDetail("note").gitGrants.first?.revocation)
        XCTAssertEqual(try f.store.execute(.init(command: .cancelTask(taskId: "note", keepBranch: true)), now: { self.at }).result, .ok)
        let expired = try XCTUnwrap(try f.store.getTaskDetail("note").gitGrants.first)
        XCTAssertNil(expired.expiry)
        XCTAssertNotNil(expired.consumption)
        XCTAssertEqual(expired.grant.argv, ["git", "rebase", "feature"])
        XCTAssertEqual(try f.store.getTaskDetail("note").gitDenials.map(\.denial.argv).first, ["git", "frobnicate", "--weird", "keep-me"])
        XCTAssertEqual(try task(f, "note").machine.state, .cancelled)
    }

    func testFifthDenialStopsTheRun() throws {
        let f = try fixture(pipeline(preset: "standard"))
        _ = try launch(f, "five")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "five", at: at)
        for index in 1...4 {
            let reply = try check(server, token, ["git", "rebase", "nope-\(index)"])
            XCTAssertFalse(reply.allow)
            XCTAssertEqual(try task(f, "five").machine.state, .running)
        }
        let last = try check(server, token, ["git", "rebase", "nope-5"])
        XCTAssertFalse(last.allow)
        let stopped = try task(f, "five")
        XCTAssertEqual(stopped.machine.state, .waitingHuman(.gitDenials))
        XCTAssertEqual(stopped.machine.attemptsUsed, 0)
        XCTAssertNil(stopped.machine.currentRunId)
        let detail = try f.store.getTaskDetail("five")
        XCTAssertEqual(detail.gitDenials.count, 5)
        XCTAssertEqual(detail.gitDenials.map(\.denial.argv), (1...5).map { ["git", "rebase", "nope-\($0)"] })
        XCTAssertEqual(detail.runs.first?.countsTowardLimits, false)
        XCTAssertEqual(detail.runs.first?.status, .killed)
    }

    func testPermanentRuleCommitsExactDraftAndOnlyChangesFutureRuns() throws {
        for scope in [PolicyScope.project, .stage("dev")] {
            let yaml = pipeline(preset: "standard")
            let f = try fixture(yaml)
            _ = try launch(f, "flight")
            let server = try MCPBoardServer(store: f.store, now: { self.at })
            defer { server.stop() }
            let token = try f.store.issueRunToken(taskId: "flight", at: at)
            _ = try check(server, token, ["git", "rebase", "feature"])
            let denial = try XCTUnwrap(try f.store.getTaskDetail("flight").gitDenials.first)
            let project = try XCTUnwrap(f.store.getSnapshot().projects.first)
            XCTAssertEqual(try f.store.execute(.init(command: .setProjectIdentity(projectId: project.id,
                identity: .init(name: "Human", email: "human@example.test")))).result, .ok)
            guard case .pipelineSource(let source) = try f.store.execute(.init(command: .getPipelineSource(projectId: project.id))).result else { return XCTFail() }
            let edited: String
            switch scope {
            case .project: edited = yaml.replacingOccurrences(of: "git: {preset: standard}", with: "git: {preset: standard, allow: [\"rebase feature\"]}")
            case .stage: edited = yaml.replacingOccurrences(of: "  - id: dev\n", with: "  - id: dev\n    git: {extend: [\"rebase feature\"]}\n")
            }
            XCTAssertNotEqual(edited, yaml)
            let draft = PipelineDraft(projectId: project.id, baseVersionHash: source.baseVersionHash,
                content: edited + "\n# preserved 👋\n", baseSourceHash: source.baseSourceHash)
            let command = CommandEnvelope(command: .addDenialToPolicy(denialId: denial.denial.denialId, scope: scope, draft: draft))
            let reply = try f.store.execute(command, now: { self.at.addingTimeInterval(1) })
            guard case .pipelineVersion(let version) = reply.result else { return XCTFail("\(reply.result)") }
            XCTAssertNotEqual(version, source.baseVersionHash)
            XCTAssertEqual(try f.store.execute(command), reply)
            guard case .pipelineSource(let accepted) = try f.store.execute(.init(command: .getPipelineSource(projectId: project.id))).result else { return XCTFail() }
            XCTAssertEqual(accepted.committedContent, draft.content)
            XCTAssertEqual(accepted.baseVersionHash, version)
            XCTAssertFalse(try check(server, token, ["git", "rebase", "feature"]).allow)
            _ = try apply(f, "flight", .requestHuman(try runId(f, "flight"), question: "pause"))
            _ = try apply(f, "flight", .answer(text: "go", requestId: nil))
            _ = try apply(f, "flight", .start("next-run"), at: at.addingTimeInterval(2))
            let next = try f.store.issueRunToken(taskId: "flight", at: at.addingTimeInterval(2))
            XCTAssertTrue(try check(server, next, ["git", "rebase", "feature"]).allow)
            let reopened = try KabanStore(path: f.path).getTaskDetail("flight")
            let update = try XCTUnwrap(reopened.gitDenials.first?.policyUpdates?.first)
            XCTAssertEqual(update.scope, scope); XCTAssertEqual(update.pipelineVersion, version)
            XCTAssertTrue(update.policy.allows("rebase feature"))
            XCTAssertTrue(reopened.gitGrants.isEmpty)
        }
    }

    func testPermanentRuleNeedsDraftAndCannotBypassHardRulesOrProjectDeny() throws {
        let yaml = pipeline(preset: "standard").replacingOccurrences(of: "git: {preset: standard}", with: "git: {preset: standard, deny: [rebase]}")
        let f = try fixture(yaml)
        _ = try launch(f, "policy")
        let server = try MCPBoardServer(store: f.store, now: { self.at }); defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "policy", at: at)
        _ = try check(server, token, ["git", "rebase", "feature"])
        let denial = try XCTUnwrap(try f.store.getTaskDetail("policy").gitDenials.last)
        XCTAssertEqual(code(try f.store.execute(.init(command: .addDenialToPolicy(denialId: denial.denial.denialId, scope: .project)))), "pipeline_draft_required")
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        guard case .pipelineSource(let source) = try f.store.execute(.init(command: .getPipelineSource(projectId: project))).result else { return XCTFail() }
        let text = yaml.replacingOccurrences(of: "  - id: dev\n", with: "  - id: dev\n    git: {extend: [\"rebase feature\"]}\n")
        let draft = PipelineDraft(projectId: project, baseVersionHash: source.baseVersionHash, content: text, baseSourceHash: source.baseSourceHash)
        let refused = try f.store.execute(.init(command: .addDenialToPolicy(denialId: denial.denial.denialId, scope: .stage("dev"), draft: draft)))
        guard case .validationIssues(let issues) = refused.result else { return XCTFail("\(refused.result)") }
        XCTAssertTrue(issues.contains { $0.code == "git_policy_rule_not_allowed" })
        XCTAssertEqual(code(try f.store.execute(.init(command: .addDenialToPolicy(denialId: denial.denial.denialId, scope: .stage("test"), draft: draft)))), "git_policy_scope")
        _ = try check(server, token, ["git", "push", "origin", "main"])
        let hard = try XCTUnwrap(try f.store.getTaskDetail("policy").gitDenials.last)
        XCTAssertEqual(code(try f.store.execute(.init(command: .addDenialToPolicy(denialId: hard.denial.denialId, scope: .project, draft: draft)))), "git_hard_invariant")
        guard case .pipelineSource(let unchanged) = try f.store.execute(.init(command: .getPipelineSource(projectId: project))).result else { return XCTFail() }
        XCTAssertEqual(unchanged, source)
    }

    func testPermanentRuleRecoveryReplaysOriginalDenialIntentOnce() throws {
        let yaml = pipeline(preset: "standard"), f = try fixture(pipeline(preset: "standard"))
        _ = try launch(f, "recover-policy")
        let server = try MCPBoardServer(store: f.store, now: { self.at }); defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "recover-policy", at: at)
        _ = try check(server, token, ["git", "rebase", "feature"])
        let denial = try XCTUnwrap(try f.store.getTaskDetail("recover-policy").gitDenials.first)
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        _ = try f.store.execute(.init(command: .setProjectIdentity(projectId: project, identity: .init(name: "Human", email: "human@example.test"))))
        guard case .pipelineSource(let source) = try f.store.execute(.init(command: .getPipelineSource(projectId: project))).result else { return XCTFail() }
        let text = yaml.replacingOccurrences(of: "git: {preset: standard}", with: "git: {preset: standard, allow: [\"rebase feature\"]}")
        let draft = PipelineDraft(projectId: project, baseVersionHash: source.baseVersionHash, content: text, baseSourceHash: source.baseSourceHash)
        let command = CommandEnvelope(command: .addDenialToPolicy(denialId: denial.denial.denialId, scope: .project, draft: draft))
        try f.store.database.write { try $0.execute(sql: "CREATE TRIGGER fail_git_policy_receipt BEFORE INSERT ON wire_command BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        XCTAssertThrowsError(try f.store.execute(command))
        XCTAssertNil(try f.store.getTaskDetail("recover-policy").gitDenials.first?.policyUpdates)
        XCTAssertEqual(try f.store.getSnapshot().pipelines.first?.versionHash, source.baseVersionHash)
        try f.store.database.write { try $0.execute(sql: "DROP TRIGGER fail_git_policy_receipt") }
        let reopened = try KabanStore(path: f.path)
        try reopened.recoverPipelineOperations()
        let reply = try reopened.execute(command, now: { XCTFail("Replay must not read clock"); return self.at })
        guard case .pipelineVersion(let version) = reply.result else { return XCTFail("\(reply.result)") }
        XCTAssertNotEqual(version, source.baseVersionHash)
        try reopened.recoverPipelineOperations()
        XCTAssertEqual(try reopened.execute(command), reply)
        let updates = try XCTUnwrap(reopened.getTaskDetail("recover-policy").gitDenials.first?.policyUpdates)
        XCTAssertEqual(updates.count, 1); XCTAssertEqual(updates.first?.pipelineVersion, version)
        XCTAssertEqual(try reopened.events(after: 0).filter {
            if case .gitPolicyUpdated = $0.event { return $0.commandId == command.commandId }; return false
        }.count, 1)
    }

    func testGrantsExpireWhenTheTaskReachesDone() throws {
        let f = try fixture(pipeline(preset: "standard", straightToDone: true))
        _ = try launch(f, "done")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "done", at: at)
        _ = try check(server, token, ["git", "rebase", "feature"])
        let denial = try XCTUnwrap(try f.store.getTaskDetail("done").gitDenials.first)
        XCTAssertEqual(try f.store.execute(.init(command: .allowGitOnce(denialId: denial.denial.denialId)), now: { self.at }).result, .ok)
        _ = try prepare(f, "done")
        _ = try apply(f, "done", .completeStage(try runId(f, "done"), summary: "finished"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(try task(f, "done").machine.state, .done)
        let grant = try XCTUnwrap(try f.store.getTaskDetail("done").gitGrants.first)
        XCTAssertEqual(grant.expiry?.reason, .taskDone)
        XCTAssertEqual(grant.grant.argv, ["git", "rebase", "feature"])
    }

    func testShimFailsClosedAndExecutesGitOnlyWhenAllowed() throws {
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-git-marker-\(UUID().uuidString)")
        let markerFlag = markerURL.appendingPathComponent("ran")
        let shimURL = markerURL.appendingPathComponent("git")
        try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: markerURL) }
        let marker = markerURL.appendingPathComponent("real-git")
        try "#!/bin/sh\nprintf ran > \"$MARKER\"\nexit 0\n".write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: marker.path)
        try KabanGitShim.install(at: shimURL)
        var closedEnv = ProcessInfo.processInfo.environment
        closedEnv.removeValue(forKey: "KABAN_GIT_CHECK_URL")
        closedEnv["KABAN_GIT_BIN"] = marker.path
        closedEnv["MARKER"] = markerFlag.path
        closedEnv["KABAN_RUN_TOKEN"] = "missing"
        let closed = try runShim(shimURL, ["status"], env: closedEnv)
        XCTAssertNotEqual(closed.status, 0)
        XCTAssertTrue(closed.stderr.contains(GitCheck.deniedMessage))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerFlag.path))

        let f = try fixture(pipeline(preset: "standard"))
        _ = try launch(f, "shim")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let token = try f.store.issueRunToken(taskId: "shim", at: at)
        var denyEnv = closedEnv
        denyEnv["KABAN_GIT_CHECK_URL"] = "http://127.0.0.1:\(server.port)/git/check"
        denyEnv["KABAN_RUN_TOKEN"] = token
        let refused = try runShim(shimURL, ["rebase", "feature"], env: denyEnv)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertTrue(refused.stderr.contains(GitCheck.deniedMessage))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerFlag.path))
        let allowed = try runShim(shimURL, ["status"], env: denyEnv)
        XCTAssertEqual(allowed.status, 0, allowed.stderr)
        XCTAssertEqual(try String(contentsOf: markerFlag, encoding: .utf8), "ran")
    }

    func testMissingTokenIsADenial() throws {
        let f = try fixture(pipeline(preset: "standard"))
        _ = try launch(f, "token")
        let server = try MCPBoardServer(store: f.store, now: { self.at })
        defer { server.stop() }
        let missing = try server.postGit(token: "", argv: ["status"], cwd: "/tmp")
        XCTAssertEqual(missing.status, 200)
        XCTAssertEqual(missing.json["allow"] as? Bool, false)
        let bad = try server.postGit(token: "not-a-run-token", argv: ["status"], cwd: "/tmp")
        XCTAssertEqual(bad.json["allow"] as? Bool, false)
        XCTAssertNotEqual(bad.json["allow"] as? Bool, true)
    }

    func testDaemonLaunchesTwice() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the git launch") }
        let f = try fixture(pipeline(preset: "standard", hooks: true))
        _ = try launch(f, "once")
        let clone = try prepare(f, "once")
        try "note".write(to: URL(fileURLWithPath: clone.clonePath).appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        _ = try apply(f, "once", .completeStage(try runId(f, "once"), summary: "Dev done"))
        let first = try runDaemon(executable, database: f.path)
        let second = try runDaemon(executable, database: f.path)
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        if let root = ProcessInfo.processInfo.environment["KABAN_PROCESS_EVIDENCE"].map(URL.init(fileURLWithPath:)) {
            try first.stderr.write(to: root.appendingPathComponent("be-12-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-12-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    private struct Reply { var allow: Bool; var message: String; var rule: String }
    private func check(_ server: MCPBoardServer, _ token: String, _ argv: [String]) throws -> Reply {
        let response = try server.postGit(token: token, argv: argv, cwd: "/tmp")
        XCTAssertEqual(response.status, 200, "\(response.json)")
        return Reply(allow: response.json["allow"] as? Bool ?? false, message: response.json["message"] as? String ?? "", rule: response.json["rule"] as? String ?? "")
    }

    private func code(_ reply: CommandReply) -> String? {
        if case .error(let error) = reply.result { return error.code }
        return nil
    }

    private func resolved(_ f: Fixture, _ id: TaskID, stage: String) throws -> EffectiveGitPolicy {
        let task = try task(f, id)
        let config = try XCTUnwrap(task.pipeline.stage(StageID(rawValue: stage)))
        return GitPolicyResolver.resolve(project: task.pipeline.git, stage: config)
    }

    private struct Fixture { let root: URL; let workspace: String; let path: String; var store: KabanStore }

    private func pipeline(preset: String, conditional: Bool = false, straightToDone: Bool = false, hooks: Bool = false) -> String {
        let hook = hooks ? "\n    hooks: {on_enter: \"printf enter >> hook-log\", on_exit: \"printf exit >> hook-log\"}" : ""
        let git = conditional ? "\n    git: {extend: [commit], when: return_reason == returned}" : ""
        let afterDev = straightToDone ? "done" : "test"
        let testStage = straightToDone ? "" : """
          - id: test
            kind: agent
            wip: 2
            agent: {model: explicit, skill: .kaban/dev.md}
            returns_to: [{stage: dev, limit: 3}]
            gates: ["/usr/bin/true"]
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review

        """
        return """
        version: 1
        board: {max_waiting_human: 4, bounce_limit_total: 5, max_runs_per_task: 12}
        git: {preset: \(preset)}
        stages:
          - {id: backlog, kind: queue, on_success: dev}
          - id: dev
            kind: agent
            wip: 2
            agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
            gates: ["/usr/bin/true"]\(hook)\(git)
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: \(afterDev)
        \(testStage)  - {id: review, kind: human, wip: 2, on_success: merge}
          - {id: merge, kind: merge, wip: 1, on_success: done}
          - {id: done, kind: terminal}
        """
    }

    private func fixture(_ yaml: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        try yaml.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try "skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["config", "user.name", "Git Test"])
        try git(repo, ["config", "user.email", "git@example.test"])
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "Pipeline"])
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result, .ok)
        _ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        return Fixture(root: root, workspace: root.appendingPathComponent("workspaces").path, path: path, store: store)
    }

    private func launch(_ f: Fixture, _ id: TaskID) throws -> RunID {
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let reply = try f.store.execute(.init(command: .createTask(projectId: project, title: id.rawValue, body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), now: { self.at }, makeTaskID: { id })
        XCTAssertEqual(reply.result, .taskCreated(id))
        _ = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-admit"), at: at)
        let started = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-run"), at: at)
        XCTAssertEqual(started.transitions.last?.task.machine.state, .running, "\(started.transitions.last?.task.machine.state ?? .done)")
        return try XCTUnwrap(started.transitions.last?.task.machine.currentRunId)
    }

    private func prepare(_ f: Fixture, _ id: TaskID) throws -> TaskCloneSnapshot {
        try f.store.prepareTaskClone(taskId: id, at: at, workspaceRoot: f.workspace)
    }

    private func task(_ f: Fixture, _ id: TaskID) throws -> DurableTask {
        try XCTUnwrap(f.store.snapshot().tasks.first { $0.card.id == id })
    }

    private func runId(_ f: Fixture, _ id: TaskID) throws -> RunID {
        try XCTUnwrap(task(f, id).machine.lastRunId)
    }

    private func apply(_ f: Fixture, _ id: TaskID, _ command: DurableTaskCommand, at when: Date? = nil) throws -> DurableReceipt {
        try f.store.apply(command, taskId: id, commandId: UUID(), at: when ?? at)
    }

    private func git(_ repo: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.environment = DaemonGit.processEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(args)")
    }

    private struct ShimOutput { var status: Int32; var stderr: String }
    private func runShim(_ url: URL, _ args: [String], env: [String: String]) throws -> ShimOutput {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        process.environment = env
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return ShimOutput(status: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private struct DaemonOutput { var status: Int32; var stderr: String }
    private func runDaemon(_ binary: URL, database: String) throws -> DaemonOutput {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--stage-pass", "--stdio", "--database", database]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return DaemonOutput(status: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
