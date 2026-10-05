import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
import KabanBoardCore
@testable import KabanDaemonCore

final class PipelineLifecycleTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 456)
    let identity = GitIdentity(name: "Pipeline Author", email: "pipeline@example.test")
    let yaml = """
    version: 1
    board: {max_waiting_human: 4, bounce_limit_total: 7, max_runs_per_task: 20}
    workspace: {warm_paths: [build], on_create: "echo warm"}
    git: {preset: strict, deny: [push]}
    suspicious_files: {patterns: ["*.secret"], max_file_mb: 2, allow: [sample.secret]}
    stages:
      - {id: backlog, kind: queue, on_success: dev}
      - id: dev
        kind: agent
        wip: 3
        agent: {model: explicit, skill: .kaban/skills/dev.md, mcp: [kaban, external]}
        gates: ["echo agent-gate"]
        hooks: {on_enter: "echo enter", on_exit: "echo exit"}
        on_success: check
      - {id: check, kind: gate, wip: 2, gates: ["echo gate"], on_success: review}
      - {id: review, kind: human, wip: 5, on_success: merge}
      - {id: merge, kind: merge, gates: ["echo merge-gate"], on_success: done}
      - {id: done, kind: terminal}

    """
    struct Fixture { let root: URL; let repo: URL; let store: KabanStore; let database: String; let project: ProjectID }
    func fixture(content: String? = nil, template: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = root.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try git(repo, ["init", "-b", "main"])
        _ = try git(repo, ["config", "user.name", identity.name]); _ = try git(repo, ["config", "user.email", identity.email])
        try "initial\n".write(to: repo.appendingPathComponent("tracked"), atomically: true, encoding: .utf8)
        if let content {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban/skills"), withIntermediateDirectories: true)
            try content.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
            try "skill v1\n".write(to: repo.appendingPathComponent(".kaban/skills/dev.md"), atomically: true, encoding: .utf8)
        }
        _ = try git(repo, ["add", "."]); _ = try git(repo, ["commit", "-m", "Initial"])
        let database = root.appendingPathComponent("store.sqlite").path, store = try KabanStore(path: database)
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: template, identity: identity))).result, .ok)
        return Fixture(root: root, repo: repo, store: store, database: database, project: try XCTUnwrap(store.getSnapshot().projects.first?.id))
    }
    @discardableResult func git(_ repo: URL, _ args: [String]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", repo.path] + args
        process.environment = DaemonGit.processEnvironment
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = pipe
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "Git \(args)", code: Int(process.terminationStatus)) }
        return output
    }
    func summary(_ f: Fixture) throws -> PipelineSummary { try XCTUnwrap(f.store.getSnapshot().pipelines.first) }
    func envelope(_ f: Fixture, _ content: String) throws -> CommandEnvelope {
        let pipeline = try summary(f)
        let draft = PipelineDraft(projectId: f.project, baseVersionHash: pipeline.versionHash, content: content, baseSourceHash: pipeline.sourceHash)
        return .init(command: .updatePipeline(projectId: f.project, contentHash: draft.contentHash, draft: draft))
    }
    func refusal(_ reply: CommandReply) throws -> CommandError {
        guard case .error(let error) = reply.result else { XCTFail("Expected error: \(reply)"); throw NSError(domain: "reply", code: 1) }; return error
    }
    func changed(_ f: Fixture, _ name: String, _ content: String) throws {
        try content.write(to: f.repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func create(_ f: Fixture, id: TaskID = "task") throws {
        XCTAssertEqual(try f.store.execute(.init(command: .createTask(projectId: f.project, title: "Task", body: "## Acceptance\n- [ ] Ready")), makeTaskID: { id }).result, .taskCreated(id))
    }
    func seedInvocation(_ f: Fixture, id: TaskID = "task", stage: StageID = "dev", run: RunID = "old-run") throws -> RunSpec {
        try create(f, id: id)
        try f.store.database.write { db in
            var task = try KabanStore.task(id, db: db)
            task.machine.stageId = stage; task.machine.state = stage == "merge" ? .gating : .running
            task.machine.currentRunId = run; task.machine.lastRunId = run; task.runSpecId = run
            task.card.stageId = stage; task.card.state = task.machine.state
            try KabanStore.freezeRunSpec(run, task: task, db: db)
            if stage != "merge" {
                var detail = try KabanStore.detail(id, db: db)
                detail.runs.append(.init(id: run, taskId: id, stageId: stage, number: 1, status: .running, requestedModel: try XCTUnwrap(task.pipeline.stage(stage)?.agent?.model), startedAt: at))
                try KabanStore.saveDetail(detail, taskId: id, db: db)
            }
            try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try KabanStore.encode(task), id.rawValue])
        }
        return try XCTUnwrap(f.store.getRunSpec(run))
    }

    func testApplyAllKindsCommitsOnlyConfigurationAndPreservesDirtyCheckout() throws {
        let f = try fixture(content: yaml), initial = try f.store.getSnapshot()
        var projection = BoardProjection(snapshot: initial)
        try changed(f, "tracked", "staged\n"); _ = try git(f.repo, ["add", "tracked"])
        try changed(f, "tracked", "unstaged\n"); try changed(f, "private.txt", "private\n")
        let staged = try git(f.repo, ["diff", "--cached", "--binary", "--", "tracked"])
        let unstaged = try git(f.repo, ["diff", "--binary", "--", "tracked"])
        try changed(f, ".kaban/skills/dev.md", "skill v2\n")
        let content = yaml.replacingOccurrences(of: "wip: 3", with: "wip: 1")
        try changed(f, ".kaban/pipeline.yaml", content)
        let request = try envelope(f, content), before = try git(f.repo, ["rev-parse", "HEAD"])
        let reply = try f.store.execute(request, now: { at })
        guard case .pipelineVersion(let hash) = reply.result else { return XCTFail("Save failed: \(reply)") }
        let pipeline = try summary(f)
        XCTAssertTrue(pipeline.isValid); XCTAssertEqual(pipeline.versionHash, hash); XCTAssertEqual(pipeline.sourceHash, hash)
        XCTAssertEqual(pipeline.stages.map(\.kind), [.queue, .agent, .gate, .human, .merge, .terminal])
        XCTAssertEqual(pipeline.stages.first(where: { $0.id == "check" })?.onFail, .init(stage: "dev", limit: 3))
        XCTAssertEqual(pipeline.stages.first(where: { $0.id == "merge" })?.onConflict, .init(stage: "dev", limit: 2))
        XCTAssertEqual(pipeline.gitPreset, .strict); XCTAssertNotNil(pipeline.projectGitPolicy)
        XCTAssertTrue(pipeline.issues.contains { $0.code == "mcp_not_allowlisted" && $0.severity == .warning })
        XCTAssertFalse(pipeline.hasUncommittedEdits)
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD^"]), before)
        XCTAssertEqual(try git(f.repo, ["diff", "--cached", "--binary", "--", "tracked"]), staged)
        XCTAssertEqual(try git(f.repo, ["diff", "--binary", "--", "tracked"]), unstaged)
        XCTAssertEqual(try String(contentsOf: f.repo.appendingPathComponent("private.txt"), encoding: .utf8), "private\n")
        let names = String(decoding: try git(f.repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"]), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(Set(names), [".kaban/pipeline.yaml", ".kaban/skills/dev.md"])
        let version = try f.store.database.read { db in try KabanStore.decode(PipelineVersion.self, XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM pipeline_version WHERE hash = ?", arguments: [hash]))) }
        XCTAssertEqual(version.pipeline.workspace.onCreate, "echo warm"); XCTAssertEqual(version.pipeline.stage("dev")?.hooks.onExit, "echo exit")
        XCTAssertEqual(version.pipeline.suspiciousFiles.maxFileMB, 2)
        for event in try f.store.events(after: initial.seq) { _ = projection.apply(event) }
        XCTAssertEqual(projection.pipelines[f.project], pipeline); XCTAssertEqual(projection.stageLoad, try f.store.getSnapshot().stageLoad)
        let reopened = try KabanStore(path: f.database), seq = try reopened.getSnapshot().seq
        XCTAssertEqual(try reopened.execute(request, now: { XCTFail("Replay read clock"); return self.at }), reply)
        XCTAssertEqual(try reopened.getSnapshot().seq, seq)
    }

    func testInvalidDraftsNeverWriteGitAndExposePaths() throws {
        let f = try fixture(content: yaml), before = try git(f.repo, ["rev-parse", "HEAD"])
        let cases = [(yaml.replacingOccurrences(of: "model: explicit", with: "model: auto"), "model_auto_forbidden"),
                     (yaml.replacingOccurrences(of: "model: explicit", with: "model: null"), "model_missing"),
                     (yaml.replacingOccurrences(of: "kind: merge", with: "kind: human"), "merge_count"),
                     (yaml.replacingOccurrences(of: "on_success: done", with: "on_success: missing"), "terminal_unreachable"),
                     (yaml.replacingOccurrences(of: "on_success: review}", with: "on_fail: {stage: backlog}, on_success: review}"), "no_return_target")]
        for (content, code) in cases {
            let reply = try f.store.execute(envelope(f, content))
            guard case .validationIssues(let issues) = reply.result else { return XCTFail("Invalid draft accepted: \(reply)") }
            XCTAssertTrue(issues.contains { $0.code == code && !$0.path.isEmpty }, "\(issues)")
            XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), before)
        }
        XCTAssertEqual(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pipeline_operation") }, 0)
    }

    func testInvalidTemplateRequiresSourceIdentityAndCanBeFixed() throws {
        let f = try fixture(template: true), pipeline = try summary(f)
        XCTAssertNil(pipeline.versionHash); XCTAssertNotNil(pipeline.sourceHash)
        let old = PipelineDraft(projectId: f.project, baseVersionHash: nil, content: yaml)
        XCTAssertEqual(try refusal(f.store.execute(.init(command: .updatePipeline(projectId: f.project, contentHash: old.contentHash, draft: old)))).code, "pipeline_source_required")
        let request = try envelope(f, yaml)
        _ = try f.store.execute(request)
        XCTAssertTrue(try summary(f).isValid)
        XCTAssertFalse(try f.store.getSnapshot().schedulerFlags.contains { if case .projectUnavailable(f.project, .pipelineInvalid, _) = $0 { true } else { false } })
    }

    func testHashAndCommittedSkillRacesCannotApplyStaleDraft() throws {
        let f = try fixture(content: yaml), request = try envelope(f, yaml + "# edit\n")
        try changed(f, ".kaban/skills/dev.md", "new committed skill\n")
        _ = try git(f.repo, ["add", ".kaban"]); _ = try git(f.repo, ["commit", "-m", "Skill change"])
        let main = try git(f.repo, ["rev-parse", "HEAD"])
        XCTAssertEqual(try refusal(f.store.execute(request)).code, CommandError.stalePipelineDraftCode)
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), main)
        var draft = PipelineDraft(projectId: f.project, baseVersionHash: try summary(f).versionHash, content: yaml)
        draft.content += "# tampered\n"
        XCTAssertEqual(try refusal(f.store.execute(.init(command: .updatePipeline(projectId: f.project, contentHash: draft.contentHash, draft: draft)))).code, CommandError.pipelineHashMismatchCode)
    }

    func testManualInvalidReloadAndWorkingDraftValidationAreSeparate() throws {
        let f = try fixture(content: yaml), old = try summary(f)
        let invalid = yaml.replacingOccurrences(of: "model: explicit", with: "model: auto")
        try changed(f, ".kaban/pipeline.yaml", invalid)
        try f.store.refreshPipelines()
        var pipeline = try summary(f)
        XCTAssertTrue(pipeline.isValid); XCTAssertEqual(pipeline.versionHash, old.versionHash); XCTAssertTrue(pipeline.hasUncommittedEdits)
        XCTAssertTrue(pipeline.uncommittedIssues?.contains { $0.code == "model_auto_forbidden" } == true)
        _ = try git(f.repo, ["add", ".kaban"]); _ = try git(f.repo, ["commit", "-m", "Manual invalid main"])
        XCTAssertEqual(try f.store.execute(.init(command: .recheck(scope: .project(projectId: f.project)))).result, .ok)
        pipeline = try summary(f)
        XCTAssertFalse(pipeline.isValid); XCTAssertNil(pipeline.versionHash); XCTAssertNotEqual(pipeline.sourceHash, old.sourceHash)
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains { if case .projectUnavailable(f.project, .pipelineInvalid, _) = $0 { true } else { false } })
        let seq = try f.store.getSnapshot().seq
        try f.store.refreshPipelines(); XCTAssertEqual(try f.store.getSnapshot().seq, seq)
        try changed(f, ".kaban/pipeline.yaml", yaml)
        _ = try git(f.repo, ["add", ".kaban"]); _ = try git(f.repo, ["commit", "-m", "Fix main"])
        try f.store.refreshPipelines(); XCTAssertTrue(try summary(f).isValid)
    }

    func testDatabaseFailureAfterGitCommitRecoversOnceAndPreservesLaterEdits() throws {
        let f = try fixture(content: yaml), request = try envelope(f, yaml + "# save\n")
        let initial = try f.store.getSnapshot()
        try f.store.database.write { try $0.execute(sql: "CREATE TRIGGER fail_pipeline_receipt BEFORE INSERT ON wire_command BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        XCTAssertThrowsError(try f.store.execute(request))
        let commit = try git(f.repo, ["rev-parse", "HEAD"])
        XCTAssertEqual(try f.store.getSnapshot(), initial)
        XCTAssertEqual(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pipeline_operation") }, 1)
        try changed(f, ".kaban/pipeline.yaml", yaml + "# later user edit\n"); _ = try git(f.repo, ["add", ".kaban"])
        let laterIndex = try git(f.repo, ["ls-files", "--stage", "-z"])
        try f.store.database.write { try $0.execute(sql: "DROP TRIGGER fail_pipeline_receipt") }
        let reopened = try KabanStore(path: f.database)
        try reopened.recoverPipelineOperations()
        let reply = try reopened.execute(request, now: { XCTFail("Recovery replay read clock"); return self.at })
        guard case .pipelineVersion = reply.result else { return XCTFail("Recovery failed") }
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), commit)
        XCTAssertEqual(try git(f.repo, ["ls-files", "--stage", "-z"]), laterIndex)
        XCTAssertEqual(try String(contentsOf: f.repo.appendingPathComponent(".kaban/pipeline.yaml"), encoding: .utf8), yaml + "# later user edit\n")
        XCTAssertTrue(try XCTUnwrap(reopened.getSnapshot().pipelines.first).hasUncommittedEdits)
        XCTAssertEqual(try reopened.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pipeline_operation") }, 0)
        try reopened.recoverPipelineOperations(); XCTAssertEqual(try reopened.execute(request), reply)
    }

    func testDirectCommitCASPreservesConcurrentMainAndRefusesLinks() throws {
        let f = try fixture(content: yaml), repository = try LocalGitRepository(path: f.repo.path)
        let plan = try repository.preparePipeline(content: yaml + "# change\n", source: repository.pipelineSource(), identity: identity, commandId: UUID())
        try changed(f, "tracked", "new main\n"); _ = try git(f.repo, ["add", "tracked"]); _ = try git(f.repo, ["commit", "-m", "Concurrent main"])
        let main = try git(f.repo, ["rev-parse", "HEAD"])
        XCTAssertThrowsError(try repository.finishPipeline(plan)) { XCTAssertEqual(($0 as? CommandError)?.code, "git_race") }
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), main)
        try changed(f, "replacement.txt", "replaced skill\n")
        let oldBlob = String(decoding: try git(f.repo, ["rev-parse", "main:.kaban/skills/dev.md"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let newBlob = String(decoding: try git(f.repo, ["hash-object", "-w", "replacement.txt"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git(f.repo, ["replace", oldBlob, newBlob])
        XCTAssertEqual(try repository.pipelineSource().files[".kaban/skills/dev.md"]?.data, Data("skill v1\n".utf8))
        let outside = f.root.appendingPathComponent("outside")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: f.repo.appendingPathComponent(".kaban/pipeline.yaml"))
        try FileManager.default.createSymbolicLink(at: f.repo.appendingPathComponent(".kaban/pipeline.yaml"), withDestinationURL: outside)
        XCTAssertThrowsError(try repository.preparePipeline(content: yaml, source: repository.pipelineSource(), identity: identity, commandId: UUID()))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
    }

    func testRunSpecAndWIPSurviveReplacementAndActiveStageRemovalIsRejected() throws {
        let f = try fixture(content: yaml), old = try seedInvocation(f)
        _ = try seedInvocation(f, id: "second", run: "second-run")
        let content = yaml.replacingOccurrences(of: "model: explicit", with: "model: replacement").replacingOccurrences(of: "wip: 3", with: "wip: 1")
        try changed(f, ".kaban/skills/dev.md", "skill v2\n")
        _ = try f.store.execute(envelope(f, content))
        XCTAssertEqual(try f.store.getRunSpec("old-run"), old)
        XCTAssertEqual(old.source?.files[".kaban/skills/dev.md"]?.data, Data("skill v1\n".utf8))
        XCTAssertEqual(try f.store.getSnapshot().stageLoad.first { $0.stageId == "dev" }?.wipUsed, 2)
        XCTAssertEqual(try f.store.getSnapshot().stageLoad.first { $0.stageId == "dev" }?.wipLimit, 1)
        XCTAssertEqual(try f.store.getTaskDetail("task").task.state, .running)
        try f.store.database.write { db in
            var next = try KabanStore.task("task", db: db)
            try KabanStore.bindPipelineForStart(&next, db: db)
            try KabanStore.freezeRunSpec("next-run", task: next, db: db)
        }
        let next = try XCTUnwrap(f.store.getRunSpec("next-run"))
        XCTAssertEqual(next.pipeline.stage("dev")?.agent?.model, "replacement")
        XCTAssertEqual(next.source?.files[".kaban/skills/dev.md"]?.data, Data("skill v2\n".utf8))
        XCTAssertNotEqual(next.pipelineVersion, old.pipelineVersion)
        let removed = content.replacingOccurrences(of: "id: dev", with: "id: replacement").replacingOccurrences(of: "on_success: dev", with: "on_success: replacement")
        let reply = try f.store.execute(envelope(f, removed))
        guard case .validationIssues(let issues) = reply.result else { return XCTFail("Removed active stage") }
        XCTAssertTrue(issues.contains { $0.code == "stage_has_active_tasks" && $0.stageId == "dev" })
        let invalid = content.replacingOccurrences(of: "model: replacement", with: "model: auto")
        try changed(f, ".kaban/pipeline.yaml", invalid); _ = try git(f.repo, ["add", ".kaban"]); _ = try git(f.repo, ["commit", "-m", "Invalid"])
        try f.store.refreshPipelines()
        XCTAssertEqual(try f.store.getRunSpec("old-run"), old)
        XCTAssertThrowsError(try f.store.database.read { db in var next = try KabanStore.task("task", db: db); try KabanStore.bindPipelineForStart(&next, db: db) })
        XCTAssertEqual(try KabanStore(path: f.database).getRunSpec("old-run"), old)
    }

    func testFakeRunFreezesEffectSpecAndMergeLocksPipelineSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try KabanStore(path: root.appendingPathComponent("fake.sqlite").path)
        _ = try store.setSettings(.init(maxConcurrentRuns: 2, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        _ = try store.registerProject(.init(id: "fake", name: "Fake", path: "/not-read", mascotSeed: "fake"), pipeline: ManagedEngineFixture.pipeline(), commandId: UUID(), at: at)
        _ = try store.createTask(card: .init(id: "fake-task", projectId: "fake", title: "Task", stageId: "queue", state: .queued(nil), hasAcceptanceCriteria: true, updatedAt: at), body: "Task", commandId: UUID(), at: at)
        _ = try store.apply(.start("admission"), taskId: "fake-task", commandId: UUID(), at: at)
        _ = try store.apply(.start("fake-run"), taskId: "fake-task", commandId: UUID(), at: at)
        XCTAssertNotNil(try store.getRunSpec("fake-run"))
        XCTAssertTrue(try store.pendingEffectItems().contains { $0.runSpecId == "fake-run" })
        let f = try fixture(content: yaml)
        _ = try seedInvocation(f, stage: "merge", run: "merge-run")
        XCTAssertEqual(try refusal(f.store.execute(envelope(f, yaml + "# save\n"))).code, "merge_in_progress")
    }
    func testInvalidMainLetsRunFinishButDefersStageExitUntilValidReload() throws {
        let f = try fixture(content: yaml), old = try seedInvocation(f)
        let invalid = yaml.replacingOccurrences(of: "model: explicit", with: "model: auto")
        try changed(f, ".kaban/pipeline.yaml", invalid)
        _ = try git(f.repo, ["add", ".kaban"]); _ = try git(f.repo, ["commit", "-m", "Invalid main"])
        try f.store.refreshPipelines()
        _ = try f.store.apply(.completeStage("old-run", summary: "Finished with old rules"), taskId: "task", commandId: UUID(), at: at)
        XCTAssertEqual(try f.store.getTaskDetail("task").runs.first?.status, .succeeded)
        XCTAssertEqual(try f.store.getTaskDetail("task").runs.first?.endReason, .completed)
        _ = try f.store.apply(.gatesPassed, taskId: "task", commandId: UUID(), at: at)
        let requestId = UUID()
        let held = try f.store.apply(.resultClean, taskId: "task", commandId: requestId, at: at)
        XCTAssertEqual(held.task.card.stageId, "dev"); XCTAssertEqual(held.task.card.state, .gating)
        XCTAssertEqual(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pipeline_deferred") }, 1)
        let reopened = try KabanStore(path: f.database)
        XCTAssertEqual(try reopened.apply(.resultClean, taskId: "task", commandId: requestId, at: at), held)
        try reopened.recoverPipelineOperations()
        try reopened.refreshProjectLocations(); try reopened.refreshPipelines()
        XCTAssertTrue(try reopened.recover(passId: UUID(), at: at).isEmpty)
        XCTAssertEqual(try reopened.getTaskDetail("task").task.state, .gating)
        XCTAssertEqual(try reopened.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pipeline_deferred") }, 1)
        try changed(f, ".kaban/pipeline.yaml", yaml)
        _ = try git(f.repo, ["add", ".kaban"]); _ = try git(f.repo, ["commit", "-m", "Fixed main"])
        try reopened.refreshPipelines()
        XCTAssertEqual(try reopened.getTaskDetail("task").task.stageId, "check")
        XCTAssertEqual(try reopened.getTaskDetail("task").task.state, .queued(nil))
        XCTAssertEqual(try reopened.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pipeline_deferred") }, 0)
        XCTAssertEqual(try reopened.getRunSpec("old-run"), old)
    }
    func testRemovalOfEmptyDownstreamStageDoesNotOrphanOldRun() throws {
        let f = try fixture(content: yaml), old = try seedInvocation(f)
        let updated = yaml.replacingOccurrences(of: "on_success: check", with: "on_success: review")
            .replacingOccurrences(of: "  - {id: check, kind: gate, wip: 2, gates: [\"echo gate\"], on_success: review}\n", with: "")
        _ = try f.store.execute(envelope(f, updated))
        _ = try f.store.apply(.completeStage("old-run", summary: "Completed"), taskId: "task", commandId: UUID(), at: at)
        _ = try f.store.apply(.gatesPassed, taskId: "task", commandId: UUID(), at: at)
        _ = try f.store.apply(.resultClean, taskId: "task", commandId: UUID(), at: at)
        XCTAssertEqual(try f.store.getTaskDetail("task").task.stageId, "review")
        XCTAssertEqual(try f.store.getRunSpec("old-run"), old)
    }
    func testTransportedDraftPreservesExistingYAMLAndRejectsDifferentDirtyEditorContent() throws {
        let f = try fixture(content: yaml), updated = yaml + "# transported\n"
        let applied = try f.store.execute(envelope(f, updated))
        guard case .pipelineVersion = applied.result else { return XCTFail("Draft was not committed") }
        XCTAssertEqual(try String(contentsOf: f.repo.appendingPathComponent(".kaban/pipeline.yaml"), encoding: .utf8), yaml)
        XCTAssertEqual(try LocalGitRepository(path: f.repo.path).pipeline(), updated)
        XCTAssertTrue(try summary(f).hasUncommittedEdits)
        let main = try git(f.repo, ["rev-parse", "main"])
        try changed(f, ".kaban/pipeline.yaml", yaml + "# different editor\n")
        XCTAssertEqual(try refusal(f.store.execute(envelope(f, updated + "# another draft\n"))).code, "pipeline_worktree_conflict")
        XCTAssertEqual(try git(f.repo, ["rev-parse", "main"]), main)
    }
    func testIndexBusyRetainsIntentAndCommandReservationUntilRecovery() throws {
        let f = try fixture(content: yaml)
        _ = try seedInvocation(f)
        let updated = yaml.replacingOccurrences(of: "on_success: check", with: "on_success: review")
            .replacingOccurrences(of: "  - {id: check, kind: gate, wip: 2, gates: [\"echo gate\"], on_success: review}\n", with: "")
        let request = try envelope(f, updated)
        let lock = f.repo.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        XCTAssertThrowsError(try f.store.execute(request))
        let committed = try git(f.repo, ["rev-parse", "main"])
        XCTAssertEqual(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pipeline_operation") }, 1)
        let another = CommandEnvelope(commandId: request.commandId, command: .pauseAll)
        XCTAssertEqual(try refusal(f.store.execute(another)).code, "command_id_conflict")
        let creation = try f.store.execute(.init(command: .createTask(projectId: f.project, title: "Task", body: "Body")))
        XCTAssertEqual(try refusal(creation).code, "project_operation_pending")
        XCTAssertEqual(try f.store.getSnapshot().tasks.count, 1)
        _ = try f.store.apply(.completeStage("old-run", summary: "Finished"), taskId: "task", commandId: UUID(), at: at)
        _ = try f.store.apply(.gatesPassed, taskId: "task", commandId: UUID(), at: at)
        _ = try f.store.apply(.resultClean, taskId: "task", commandId: UUID(), at: at)
        XCTAssertEqual(try f.store.getTaskDetail("task").task.stageId, "dev")
        try FileManager.default.removeItem(at: lock)
        let reopened = try KabanStore(path: f.database)
        try reopened.recoverPipelineOperations()
        guard case .pipelineVersion = try reopened.execute(request).result else { return XCTFail("Pending save did not recover") }
        XCTAssertEqual(try git(f.repo, ["rev-parse", "main"]), committed)
        XCTAssertEqual(try reopened.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pipeline_operation") }, 0)
        XCTAssertEqual(try reopened.getTaskDetail("task").task.stageId, "review")
    }
    func testSaveCannotExecuteRepositoryFiltersOrCommitSigner() throws {
        let f = try fixture(content: yaml), script = f.root.appendingPathComponent("planted")
        let marker = f.root.appendingPathComponent("executed")
        try "#!/bin/sh\ntouch '\(marker.path)'\ncat\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try changed(f, ".gitattributes", ".kaban/** filter=evil\n")
        _ = try git(f.repo, ["add", ".gitattributes"]); _ = try git(f.repo, ["commit", "-m", "Attributes"])
        _ = try git(f.repo, ["config", "filter.evil.clean", script.path])
        _ = try git(f.repo, ["config", "filter.evil.required", "true"])
        _ = try git(f.repo, ["config", "commit.gpgSign", "true"])
        _ = try git(f.repo, ["config", "gpg.program", script.path])
        let reply = try f.store.execute(envelope(f, yaml + "# safe save\n"))
        guard case .pipelineVersion = reply.result else { return XCTFail("Save failed: \(reply)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testOutsideSkillIsPinnedWithoutCommittingItsWorkingCopy() throws {
        let f = try fixture(content: yaml), name = "dev[1].md"
        try changed(f, name, "outside v1\n")
        _ = try git(f.repo, ["add", name]); _ = try git(f.repo, ["commit", "-m", "Outside skill"])
        let updated = yaml.replacingOccurrences(of: ".kaban/skills/dev.md", with: "\"" + name + "\"")
        let reply = try f.store.execute(envelope(f, updated))
        guard case .pipelineVersion(let hash) = reply.result else { return XCTFail("Save failed: \(reply)") }
        let old = try seedInvocation(f)
        XCTAssertEqual(old.source?.referencedSkills[name]?.data, Data("outside v1\n".utf8))
        try changed(f, name, "outside v2\n"); _ = try git(f.repo, ["add", name])
        let staged = try git(f.repo, ["diff", "--cached", "--binary", "--", name])
        let next = updated.replacingOccurrences(of: "model: explicit", with: "model: next")
        try changed(f, ".kaban/pipeline.yaml", next)
        _ = try f.store.execute(envelope(f, next))
        XCTAssertEqual(try git(f.repo, ["show", "main:" + name]), Data("outside v1\n".utf8))
        XCTAssertEqual(try git(f.repo, ["diff", "--cached", "--binary", "--", name]), staged)
        let beforeSkillCommit = try summary(f).versionHash
        _ = try git(f.repo, ["commit", "-m", "Updated outside skill"])
        try f.store.refreshPipelines()
        XCTAssertNotEqual(try summary(f).versionHash, beforeSkillCommit)
        XCTAssertNotEqual(try summary(f).versionHash, hash)
        XCTAssertEqual(try f.store.getRunSpec("old-run"), old)
        XCTAssertEqual(try LocalGitRepository(path: f.repo.path).pipelineSource().referencedSkills[name]?.data, Data("outside v2\n".utf8))
    }
    func testRecoveryPreservesAcceptedVersionBehindNewerInvalidMain() throws {
        let f = try fixture(content: yaml), request = try envelope(f, yaml + "# accepted\n")
        try f.store.database.write { try $0.execute(sql: "CREATE TRIGGER fail_pipeline_receipt BEFORE INSERT ON wire_command BEGIN SELECT RAISE(ABORT, 'fault'); END") }
        XCTAssertThrowsError(try f.store.execute(request))
        let accepted = try LocalGitRepository(path: f.repo.path).pipelineSource(), hash = try accepted.versionHash()
        let invalid = yaml.replacingOccurrences(of: "model: explicit", with: "model: auto")
        try changed(f, ".kaban/pipeline.yaml", invalid)
        _ = try git(f.repo, ["add", ".kaban"]); _ = try git(f.repo, ["commit", "-m", "Newer invalid main"])
        let latest = try git(f.repo, ["rev-parse", "main"])
        try f.store.database.write { try $0.execute(sql: "DROP TRIGGER fail_pipeline_receipt") }
        let reopened = try KabanStore(path: f.database)
        try reopened.recoverPipelineOperations()
        let reply = try reopened.execute(request)
        XCTAssertEqual(reply.result, .pipelineVersion(hash: hash))
        XCTAssertEqual(try git(f.repo, ["rev-parse", "main"]), latest)
        XCTAssertFalse(try XCTUnwrap(reopened.getSnapshot().pipelines.first).isValid)
        XCTAssertEqual(try reopened.database.read { db in
            try KabanStore.decode(PipelineVersion.self, XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM pipeline_version WHERE project_id = ? AND hash = ?", arguments: [f.project.rawValue, hash]))).source
        }, accepted)
        XCTAssertEqual(try reopened.execute(request, now: { XCTFail("Replay read clock"); return self.at }), reply)
    }
    func testStagedOnlyConfigurationChangeIsReported() throws {
        let f = try fixture(content: yaml)
        try changed(f, ".kaban/skills/dev.md", "staged skill\n"); _ = try git(f.repo, ["add", ".kaban/skills/dev.md"])
        try changed(f, ".kaban/skills/dev.md", "skill v1\n")
        try f.store.refreshPipelines()
        XCTAssertTrue(try summary(f).hasUncommittedEdits)
        XCTAssertTrue(try summary(f).isValid)
    }
}
