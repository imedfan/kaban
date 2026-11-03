import Foundation
import XCTest
import KabanKit
import KabanProtocol
import KabanBoardCore
@testable import KabanDaemonCore

extension ProjectLifecycleTests {
    func testIgnoredTemplateOnFeatureRegistersBacklogWithoutCommitOrIndexChanges() throws {
        let f = try fixture()
        try ".kaban/\n".write(to: f.repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try git(f.repo, ["add", ".gitignore"]); _ = try git(f.repo, ["commit", "-m", "Ignore local pipeline"])
        _ = try git(f.repo, ["switch", "-c", "feature"])
        let head = try git(f.repo, ["rev-parse", "HEAD"])
        let index = try Data(contentsOf: f.repo.appendingPathComponent(".git/index"))
        let exclude = try Data(contentsOf: f.repo.appendingPathComponent(".git/info/exclude"))
        let request = CommandEnvelope(command: .addProject(path: f.repo.path, createTemplate: true, identity: identity))
        let reply = try f.store.execute(request)
        XCTAssertEqual(reply.result, .ok)
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first)
        let summary = try XCTUnwrap(f.store.getSnapshot().pipelines.first)
        XCTAssertFalse(summary.isValid)
        XCTAssertTrue(summary.issues.contains { $0.code == "model_missing" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.repo.path + "/.kaban/skills/dev.md"))
        try create(f.store, project: project.id)
        XCTAssertEqual(try f.store.getTaskDetail("task").task.stageId, "backlog")
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), head)
        XCTAssertEqual(text(try git(f.repo, ["branch", "--show-current"])), "feature")
        XCTAssertEqual(try Data(contentsOf: f.repo.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: f.repo.appendingPathComponent(".git/info/exclude")), exclude)
        XCTAssertEqual(text(try git(f.repo, ["status", "--porcelain"])), "")
        XCTAssertEqual(try KabanStore(path: f.database).execute(request), reply)
    }
}

extension PipelineLifecycleTests {
    func testRootDeletionReturnAndSkillEditReloadWithoutAnyGitChange() throws {
        let f = try fixture(content: yaml)
        let original = try summary(f)
        let oldRun = try seedInvocation(f)
        let head = try git(f.repo, ["rev-parse", "HEAD"])
        let directory = f.repo.appendingPathComponent(".kaban"), saved = f.root.appendingPathComponent("saved")
        try FileManager.default.moveItem(at: directory, to: saved)
        try f.store.refreshPipelines()
        XCTAssertTrue(try summary(f).issues.contains { $0.code == "pipeline_missing" })
        XCTAssertNil(try summary(f).versionHash)
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains { if case .projectUnavailable(f.project, .noPipeline, _) = $0 { true } else { false } })
        XCTAssertEqual(try f.store.getRunSpec("old-run"), oldRun)
        try FileManager.default.moveItem(at: saved, to: directory)
        XCTAssertEqual(try f.store.execute(.init(command: .recheck(scope: .project(projectId: f.project)))).result, .ok)
        XCTAssertEqual(try summary(f).versionHash, original.versionHash)
        try changed(f, ".kaban/skills/dev.md", "uncommitted skill v2\n")
        try f.store.refreshPipelines()
        XCTAssertNotEqual(try summary(f).versionHash, original.versionHash)
        XCTAssertEqual(try f.store.getRunSpec("old-run"), oldRun)
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), head)
        let seq = try f.store.getSnapshot().seq
        try f.store.refreshPipelines()
        XCTAssertEqual(try f.store.getSnapshot().seq, seq)
    }

    func testPrewrittenNativeDraftSurvivesObserverReloadAndRejectsConcurrentSkillEdit() throws {
        let f = try fixture(content: yaml)
        func read() throws -> PipelineSourceContent {
            guard case .pipelineSource(let source) = try f.store.execute(.init(command: .getPipelineSource(projectId: f.project))).result else {
                throw NSError(domain: "source", code: 1)
            }
            return source
        }
        let initial = try read(), updated = yaml + "# exact editor\n"
        var draft = PipelineDraft(projectId: f.project, baseVersionHash: initial.baseVersionHash, content: updated, baseSourceHash: initial.baseSourceHash)
        draft.requiresExactWorkingContent = true
        try PipelineFileWriter.write(updated, source: initial)
        try f.store.refreshPipelines()
        let request = CommandEnvelope(command: .updatePipeline(projectId: f.project, contentHash: draft.contentHash, draft: draft))
        XCTAssertEqual(try f.store.execute(request).result, .pipelineVersion(hash: try XCTUnwrap(summary(f).versionHash)))
        let nextSource = try read(), next = updated + "# next\n"
        var raced = PipelineDraft(projectId: f.project, baseVersionHash: nextSource.baseVersionHash, content: next, baseSourceHash: nextSource.baseSourceHash)
        raced.requiresExactWorkingContent = true
        try PipelineFileWriter.write(next, source: nextSource)
        try changed(f, ".kaban/skills/dev.md", "external skill edit\n")
        try f.store.refreshPipelines()
        XCTAssertEqual(try refusal(f.store.execute(.init(command: .updatePipeline(projectId: f.project, contentHash: raced.contentHash, draft: raced)))).code, CommandError.stalePipelineDraftCode)
        XCTAssertEqual(try String(contentsOf: f.repo.appendingPathComponent(".kaban/skills/dev.md"), encoding: .utf8), "external skill edit\n")
    }

    func testIgnoredRootPipelineStartsWithoutCloneCopyAndFreezesAbsoluteSkillPath() throws {
        let f = try fixture()
        _ = try git(f.repo, ["switch", "-c", "feature"])
        try changed(f, ".gitignore", ".kaban/\n")
        try FileManager.default.createDirectory(at: f.repo.appendingPathComponent(".kaban/skills"), withIntermediateDirectories: true)
        try changed(f, ".kaban/pipeline.yaml", yaml)
        try changed(f, ".kaban/skills/dev.md", "local skill\n")
        try f.store.refreshPipelines()
        _ = try f.store.setSettings(.init(maxConcurrentRuns: 2, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        let body = "Task\n\n## Критерии приёмки\n- [ ] Ready"
        XCTAssertEqual(try f.store.execute(.init(command: .createTask(projectId: f.project, title: "Task", body: body)), makeTaskID: { "task" }).result, .taskCreated("task"))
        _ = try f.store.tick(tickId: UUID(), runId: "admit", at: at)
        let started = try f.store.tick(tickId: UUID(), runId: "root-run", at: at)
        XCTAssertEqual(started.transitions.last?.task.machine.state, .running)
        let spec = try XCTUnwrap(f.store.getRunSpec("root-run"))
        let token = try f.store.issueRunToken(taskId: "task", at: at)
        let context = try f.store.performBoardTool(token: token, name: "get_task_context", arguments: [:], at: at)
        XCTAssertEqual(context.body, body)
        XCTAssertEqual(context.stage?.id, "dev")
        XCTAssertEqual(context.stage?.gates, ["echo agent-gate"])
        XCTAssertEqual(context.pipelineVersion, spec.pipelineVersion)
        try changed(f, ".kaban/pipeline.yaml", yaml.replacingOccurrences(of: "echo agent-gate", with: "echo changed gate"))
        try f.store.refreshPipelines()
        let frozenContext = try f.store.performBoardTool(token: token, name: "get_task_context", arguments: [:], at: at)
        XCTAssertEqual(frozenContext.stage?.gates, ["echo agent-gate"])
        XCTAssertEqual(frozenContext.pipelineVersion, spec.pipelineVersion)
        let clone = try f.store.prepareTaskClone(taskId: "task", at: at, workspaceRoot: f.root.appendingPathComponent("workspaces").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.clonePath + "/.kaban"))
        let exclude = try String(contentsOfFile: clone.clonePath + "/.git/info/exclude", encoding: .utf8)
        XCTAssertFalse(exclude.contains(".kaban"))
        let parts = try XCTUnwrap(spec.promptParts)
        XCTAssertTrue(CursorLaunch.render(parts).contains(f.repo.path + "/.kaban/skills/dev.md"))
        XCTAssertEqual(spec.source?.files[".kaban/skills/dev.md"]?.data, Data("local skill\n".utf8))
        XCTAssertEqual(try f.store.getTaskDetail("task").body, body)
    }

    #if os(macOS)
    func testFSEventsReloadRootFilesWithoutPolling() async throws {
        let f = try fixture(content: yaml)
        let changed = expectation(description: "FSEvents adopts root YAML")
        changed.assertForOverFulfill = false
        let store = f.store, project = f.project
        let observer = ProjectPipelineObserver {
            do {
                try store.refreshPipelines(only: project)
                if try store.getSnapshot().pipelines.first?.stages.first(where: { $0.id == "dev" })?.model == "event-model" { changed.fulfill() }
            } catch { }
        }
        observer.watch(projectPaths: [f.repo.path])
        defer { observer.stop() }
        try self.changed(f, ".kaban/pipeline.yaml", yaml.replacingOccurrences(of: "model: explicit", with: "model: event-model"))
        await fulfillment(of: [changed], timeout: 10)
        XCTAssertEqual(try summary(f).stages.first { $0.id == "dev" }?.model, "event-model")
    }
    #endif
}
