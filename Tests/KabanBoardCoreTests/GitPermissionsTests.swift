import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class GitPermissionsTests: XCTestCase {
    func testLifecycleUsesBackendTimesAndDoesNotTreatDeliveryAsConsumption() {
        let detail = TaskDetail(seq: 0, task: Fix.card("task", state: .running), feed: [], runs: [], humanRequests: [])
        var grant = GitGrantSnapshot(grant: .init(grantId: "grant", denialId: "denial", argv: ["git", "rebase", "feature"], by: .human),
                                     taskId: "task", stageId: "dev", createdAt: Fix.t0)
        let created = GitGrantPresentation(grant, detail: detail)
        XCTAssertEqual(created.state, .created); XCTAssertEqual(created.steps.map(\.at), [Fix.t0])
        XCTAssertTrue(created.notice?.contains("следующем вызове") == true)
        grant.delivery = .init(grantId: "grant", runId: "run", via: .mcpResponse)
        grant.deliveredAt = Fix.t0.addingTimeInterval(2)
        let delivered = GitGrantPresentation(grant, detail: detail)
        XCTAssertEqual(delivered.state, .delivered); XCTAssertEqual(delivered.steps.count, 2)
        XCTAssertEqual(delivered.steps.last?.at, grant.deliveredAt)
        grant.consumption = .init(grantId: "grant", runId: "run")
        let consumed = GitGrantPresentation(grant, detail: detail)
        XCTAssertEqual(consumed.state, .consumed); XCTAssertNil(consumed.steps.last?.at)
        XCTAssertNil(consumed.notice)
        grant.expiry = .init(grantId: "grant", reason: .taskCancelled)
        let legacy = GitGrantPresentation(grant, detail: detail)
        XCTAssertEqual(legacy.state, .inconsistent); XCTAssertEqual(legacy.steps.count, 4)
        grant.consumption = nil; grant.expiredAt = Fix.t0.addingTimeInterval(9)
        XCTAssertEqual(GitGrantPresentation(grant, detail: detail).state, .expired)
    }

    @MainActor func testGitCommandsNeedTheirOwnEventAndPolicyNeedsProjectScopeAndNewVersion() throws {
        let storage = MemoryKeyValueStore(), journal = try ClientCommandJournal(storage: storage, key: "git")
        let allow = CommandEnvelope(command: .allowGitOnce(denialId: "d"))
        try journal.begin(allow); try journal.receive(.init(commandId: allow.commandId, seq: nil, result: .ok))
        XCTAssertTrue(journal.records[0].isPending)
        try journal.observe(Fix.envelope(1, .gitGrantCreated(.init(grantId: "g", denialId: "other", argv: [], by: .human)), commandId: allow.commandId))
        XCTAssertTrue(journal.records[0].isPending)
        try journal.observe(Fix.envelope(2, .gitGrantCreated(.init(grantId: "g", denialId: "d", argv: [], by: .human)), commandId: allow.commandId))
        XCTAssertEqual(journal.records[0].phase, .applied)
        let draft = PipelineDraft(projectId: Fix.project, baseVersionHash: "v1", content: "exact", baseSourceHash: "s1")
        let policy = CommandEnvelope(command: .addDenialToPolicy(denialId: "d", scope: .stage("dev"), draft: draft))
        try journal.begin(policy)
        try journal.receive(.init(commandId: policy.commandId, seq: nil, result: .pipelineVersion(hash: "v2")))
        for update in [GitPolicyUpdated(projectId: Fix.other, scope: .stage("dev"), pipelineVersion: "v2"),
                       .init(projectId: Fix.project, scope: .project, pipelineVersion: "v2"),
                       .init(projectId: Fix.project, scope: .stage("dev"), pipelineVersion: "v1")] {
            try journal.observe(Fix.envelope(3, .gitPolicyUpdated(update), commandId: policy.commandId))
            XCTAssertTrue(journal.records[1].isPending)
        }
        try journal.observe(Fix.envelope(4, .gitPolicyUpdated(.init(projectId: Fix.project, scope: .stage("dev"), pipelineVersion: "v2")), commandId: policy.commandId))
        let reopened = try ClientCommandJournal(storage: storage, key: "git")
        XCTAssertEqual(reopened.records[1].phase, .applied)
        XCTAssertEqual(reopened.records[1].envelope, policy)
    }

    @MainActor func testPolicyCommandUsesExactWriterAndDenialScopeInsteadOfOrdinaryUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let yaml = "version: 1\ngit: {preset: standard}\nstages:\n  - {id: dev, kind: agent}\n"
        let path = root.appendingPathComponent(".kaban/pipeline.yaml")
        try yaml.write(to: path, atomically: true, encoding: .utf8)
        let source = PipelineSourceContent(projectId: Fix.project, path: path.path, baseVersionHash: "v1", baseSourceHash: "s1", committedContent: yaml, workingContent: yaml, worktreeSourceHash: "s1")
        let client = EditorTestClient(source: source), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "git-policy")
        let loop = Task { await session.run() }; defer { loop.cancel(); session.stop() }
        for _ in 0..<400 { if session.canSend { break }; try await Task.sleep(for: .milliseconds(5)) }
        let editor = PipelineEditorStore(projectID: Fix.project, client: client, session: session)
        await editor.readSource()
        editor.setGitRule("rebase feature", allowPath: "git.allow", denyPath: "git.deny", decision: .allow)
        await editor.validate(); XCTAssertTrue(editor.canApply)
        await editor.applyGitDenial("d", scope: .project)
        let command = try XCTUnwrap(client.applied.first)
        guard case .addDenialToPolicy(let id, let scope, let draft) = command.command else { return XCTFail() }
        XCTAssertEqual(id, "d"); XCTAssertEqual(scope, .project)
        XCTAssertEqual(draft?.requiresExactWorkingContent, true)
        XCTAssertEqual(draft?.content, try String(contentsOf: path, encoding: .utf8))
        XCTAssertTrue(draft?.content.contains("\"rebase feature\"") == true)
        XCTAssertEqual(editor.receipt?.phase, .awaitingEvent)
    }
}
