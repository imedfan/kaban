import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
import KabanBoardCore
@testable import KabanDaemonCore

final class ProjectLifecycleTests: XCTestCase {
    let identity = GitIdentity(name: " Kaban Author ", email: " kaban@example.test ")
    let at = Date(timeIntervalSince1970: 123)
    struct Fixture { let root: URL; let repo: URL; let database: String; let store: KabanStore }
    func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = root.appendingPathComponent("Repository")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try git(repo, ["init", "-b", "main"])
        _ = try git(repo, ["config", "user.name", "Repository Author"])
        _ = try git(repo, ["config", "user.email", "repo@example.test"])
        try "initial\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try git(repo, ["add", "tracked.txt"]); _ = try git(repo, ["commit", "-m", "Initial"])
        let database = root.appendingPathComponent("store.sqlite").path
        return Fixture(root: root, repo: repo, database: database, store: try KabanStore(path: database))
    }
    @discardableResult func git(_ repo: URL, _ args: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.environment = DaemonGit.processEnvironment
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "Git test \(args)", code: Int(process.terminationStatus)) }
        return data
    }
    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines) }
    func refusal(_ reply: CommandReply) throws -> CommandError {
        guard case .error(let error) = reply.result else { XCTFail("Expected refusal: \(reply)"); throw NSError(domain: "reply", code: 1) }; return error
    }
    @discardableResult func send(_ command: Command, _ store: KabanStore) throws -> CommandReply { try store.execute(.init(command: command), now: { at }) }
    func add(_ f: Fixture, template: Bool = false) throws -> ProjectSummary {
        XCTAssertEqual(try send(.addProject(path: f.repo.path, createTemplate: template, identity: identity), f.store).result, .ok)
        return try XCTUnwrap(f.store.getSnapshot().projects.first)
    }
    func create(_ store: KabanStore, project: ProjectID, id: TaskID = "task") throws {
        let reply = try store.execute(.init(command: .createTask(projectId: project, title: "Task", body: "Description\n\n## Критерии приёмки\n- [ ] Works")), now: { at }, makeTaskID: { id })
        XCTAssertEqual(reply.result, .taskCreated(id))
    }
    func assertProjection(_ projection: BoardProjection, _ snapshot: Snapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(projection.projects, Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) }), file: file, line: line)
        XCTAssertEqual(projection.pipelines, Dictionary(uniqueKeysWithValues: snapshot.pipelines.map { ($0.projectId, $0) }), file: file, line: line)
        XCTAssertEqual(projection.tasks, Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) }), file: file, line: line)
        XCTAssertEqual(projection.ephemeral.schedulerFlags, snapshot.schedulerFlags, file: file, line: line)
        XCTAssertEqual(projection.stageLoad, snapshot.stageLoad, file: file, line: line)
        XCTAssertEqual(projection.stateSeq, snapshot.seq, file: file, line: line)
        XCTAssertFalse(projection.needsResync, file: file, line: line)
    }
    func testPreflightFailuresNeverLeaveProjectOrTemplate() throws {
        let f = try fixture(), folder = f.root.appendingPathComponent("not-git")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let nonGit = try send(.addProject(path: folder.path, createTemplate: true, identity: identity), f.store)
        XCTAssertEqual(try refusal(nonGit).code, "not_git_repository")
        let invalid = CommandEnvelope(command: .addProject(path: f.repo.path, createTemplate: true, identity: .init(name: " \n ", email: " \t ")))
        let reply = try f.store.execute(invalid)
        XCTAssertEqual(try refusal(reply).code, "identity_required")
        XCTAssertEqual(try refusal(reply).params, ["invalid": "name", "missing": "email"])
        _ = try git(f.repo, ["config", "user.name", " Found name "])
        _ = try git(f.repo, ["config", "user.email", " \r\n "])
        let read = try send(.addProject(path: f.repo.path, createTemplate: true), f.store)
        XCTAssertEqual(try refusal(read).params, ["name": "Found name", "invalid": "email"])
        XCTAssertTrue(try f.store.getSnapshot().projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.repo.path + "/.kaban"))
        XCTAssertEqual(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_operation") }, 0)
        let reopened = try KabanStore(path: f.database)
        XCTAssertEqual(try reopened.execute(invalid, now: { XCTFail("Refusal replay read clock"); return self.at }), reply)
    }
    func testDirtyTemplateCommitPreservesStagedUnstagedAndUntrackedFiles() throws {
        let f = try fixture()
        try "staged\n".write(to: f.repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try git(f.repo, ["add", "tracked.txt"])
        try "unstaged\n".write(to: f.repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "secret\n".write(to: f.repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let staged = try git(f.repo, ["diff", "--cached", "--binary", "--", "tracked.txt"])
        let unstaged = try git(f.repo, ["diff", "--binary", "--", "tracked.txt"])
        let original = try git(f.repo, ["rev-parse", "HEAD"])
        let hooks = f.root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appendingPathComponent("pre-commit")
        try "#!/bin/sh\ntouch '\(f.root.path)/hook-ran'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try git(f.repo, ["config", "core.hooksPath", hooks.path])
        let envelope = CommandEnvelope(command: .addProject(path: f.repo.path, createTemplate: true, identity: identity))
        let reply = try f.store.execute(envelope, now: { at })
        XCTAssertEqual(reply.result, .ok)
        XCTAssertEqual(try git(f.repo, ["diff", "--cached", "--binary", "--", "tracked.txt"]), staged)
        XCTAssertEqual(try git(f.repo, ["diff", "--binary", "--", "tracked.txt"]), unstaged)
        XCTAssertEqual(try String(contentsOf: f.repo.appendingPathComponent("untracked.txt"), encoding: .utf8), "secret\n")
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD^"]), original)
        XCTAssertEqual(Set(text(try git(f.repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])).split(separator: "\n").map(String.init)), Set(PipelineTemplate.files.keys))
        XCTAssertEqual(text(try git(f.repo, ["show", "-s", "--format=%an <%ae>", "HEAD"])), "Kaban Author <kaban@example.test>")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path + "/hook-ran"))
        XCTAssertTrue(try git(f.repo, ["diff", "--cached", "--", ".kaban"]).isEmpty)
        XCTAssertTrue(try git(f.repo, ["diff", "--", ".kaban"]).isEmpty)
        let snapshot = try f.store.getSnapshot(), project = try XCTUnwrap(snapshot.projects.first)
        XCTAssertEqual(project.identity, try identity.validated()); XCTAssertEqual(project.mascotSeed, project.id.rawValue)
        XCTAssertFalse(try XCTUnwrap(snapshot.pipelines.first).isValid)
        XCTAssertTrue(snapshot.schedulerFlags.contains { if case .projectUnavailable(project.id, .pipelineInvalid, _) = $0 { true } else { false } })
        let reopened = try KabanStore(path: f.database), seq = snapshot.seq
        XCTAssertEqual(try reopened.execute(envelope, now: { XCTFail("Replay read clock"); return self.at }), reply)
        XCTAssertEqual(try reopened.getSnapshot().seq, seq)
        let link = f.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.repo)
        XCTAssertEqual(try refusal(send(.addProject(path: link.path, createTemplate: false, identity: identity), reopened)).code, "project_already_registered")
    }
    func testMissingAndMalformedPipelinesStillStoreBacklog() throws {
        let f = try fixture(), project = try add(f)
        try create(f.store, project: project.id)
        XCTAssertEqual(try f.store.getTaskDetail("task").task.stageId, "backlog")
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains(.projectUnavailable(project.id, .noPipeline, detail: "Нет закоммиченного пайплайна.")))
        XCTAssertThrowsError(try f.store.apply(.start("real-run"), taskId: "task", commandId: UUID(), at: at))
        let bad = try fixture()
        try FileManager.default.createDirectory(at: bad.repo.appendingPathComponent(".kaban"), withIntermediateDirectories: false)
        try "stages: [ broken".write(to: bad.repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        _ = try git(bad.repo, ["add", ".kaban"]); _ = try git(bad.repo, ["commit", "-m", "Invalid pipeline"])
        let badProject = try add(bad, template: true)
        try create(bad.store, project: badProject.id)
        XCTAssertFalse(try XCTUnwrap(bad.store.getSnapshot().pipelines.first).isValid)
        XCTAssertEqual(try String(contentsOf: bad.repo.appendingPathComponent(".kaban/pipeline.yaml"), encoding: .utf8), "stages: [ broken")
    }
    func testLocalMainAndTemplateCheckoutDiagnostics() throws {
        let f = try fixture()
        _ = try git(f.repo, ["branch", "-m", "main", "master"])
        XCTAssertEqual(try refusal(send(.addProject(path: f.repo.path, createTemplate: true, identity: identity), f.store)).code, "base_branch_required")
        XCTAssertTrue(try f.store.getSnapshot().projects.isEmpty)
        _ = try git(f.repo, ["branch", "main"])
        XCTAssertEqual(try refusal(send(.addProject(path: f.repo.path, createTemplate: true, identity: identity), f.store)).code, "template_checkout_required")
        XCTAssertEqual(text(try git(f.repo, ["branch", "--show-current"])), "master")
        _ = try add(f)
        XCTAssertEqual(text(try git(f.repo, ["branch", "--show-current"])), "master")
    }
    func testBranchesAndGatesReadCommittedMainAndRemainFreshQueries() throws {
        let f = try fixture()
        try "// swift-tools-version: 6.1\n".write(to: f.repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        _ = try git(f.repo, ["add", "Package.swift"]); _ = try git(f.repo, ["commit", "-m", "Build descriptor"])
        let p = try add(f), envelope = CommandEnvelope(command: .listBranches(projectId: p.id))
        XCTAssertEqual(try f.store.execute(envelope).result, .branches(["main"]))
        _ = try git(f.repo, ["branch", "feature"])
        XCTAssertEqual(try f.store.execute(envelope).result, .branches(["feature", "main"]))
        try FileManager.default.removeItem(at: f.repo.appendingPathComponent("Package.swift"))
        XCTAssertEqual(try send(.detectGates(projectId: p.id), f.store).result, .gates(["swift build", "swift test"]))
    }
    func testMissingObserverRelinkPreservesIdTasksHistoryAndDoesNotSpam() throws {
        let f = try fixture(), p = try add(f)
        try create(f.store, project: p.id)
        let initial = try f.store.getSnapshot()
        try f.store.refreshProjectLocations(at: at)
        XCTAssertEqual(try f.store.getSnapshot(), initial)
        let moved = f.root.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: f.repo, to: moved)
        try f.store.refreshProjectLocations(at: at)
        let missing = try f.store.getSnapshot()
        XCTAssertEqual(missing.projects.first?.availability, .missing)
        XCTAssertEqual(missing.tasks, initial.tasks)
        XCTAssertTrue(missing.schedulerFlags.contains(.projectUnavailable(p.id, .projectMissing, detail: nil)))
        let reopened = try KabanStore(path: f.database)
        XCTAssertEqual(try reopened.getSnapshot(), missing)
        XCTAssertEqual(try send(.relinkProject(projectId: p.id, path: moved.path), reopened).result, .ok)
        let linked = try reopened.getSnapshot()
        XCTAssertEqual(linked.projects.first?.id, p.id); XCTAssertEqual(linked.projects.first?.path, moved.resolvingSymlinksInPath().path)
        XCTAssertEqual(linked.projects.first?.availability, .available)
        XCTAssertEqual(linked.tasks, initial.tasks)
        var projection = BoardProjection(snapshot: initial)
        for event in try reopened.events(after: initial.seq) { _ = projection.apply(event) }
        assertProjection(projection, linked)
    }
    func testRemoveRetainsRepositoryAndDetailsAndAllowsNewRegistration() throws {
        let f = try fixture(), p = try add(f)
        try create(f.store, project: p.id)
        let before = try f.store.getSnapshot()
        let envelope = CommandEnvelope(command: .removeProject(projectId: p.id)), reply = try f.store.execute(envelope)
        XCTAssertEqual(reply.result, .ok)
        let removed = try f.store.getSnapshot()
        XCTAssertTrue(removed.projects.isEmpty); XCTAssertTrue(removed.tasks.isEmpty); XCTAssertTrue(removed.pipelines.isEmpty)
        XCTAssertEqual(try f.store.getTaskDetail("task").task.state.status, .cancelled)
        XCTAssertEqual(try f.store.getTaskDetail("task").body, "Description\n\n## Критерии приёмки\n- [ ] Works")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.repo.path + "/tracked.txt"))
        let reopened = try KabanStore(path: f.database)
        XCTAssertEqual(try reopened.execute(envelope), reply)
        XCTAssertEqual(try reopened.getSnapshot(), removed)
        let second = try add(Fixture(root: f.root, repo: f.repo, database: f.database, store: reopened))
        XCTAssertNotEqual(second.id, p.id)
        XCTAssertEqual(try reopened.getTaskDetail("task").task.projectId, p.id)
        var projection = BoardProjection(snapshot: before)
        for event in try f.store.events(after: before.seq).filter({ $0.seq <= removed.seq }) { _ = projection.apply(event) }
        assertProjection(projection, removed)
    }
    func testDatabaseFailureAfterGitCommitRecoversWithoutDuplicateOrOverwritingEdits() throws {
        let f = try fixture()
        try f.store.database.write { db in try db.execute(sql: "CREATE TRIGGER fail_project_reply BEFORE INSERT ON wire_command BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        let envelope = CommandEnvelope(command: .addProject(path: f.repo.path, createTemplate: true, identity: identity))
        XCTAssertThrowsError(try f.store.execute(envelope))
        XCTAssertTrue(try f.store.getSnapshot().projects.isEmpty)
        XCTAssertEqual(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_operation") }, 1)
        let commit = try git(f.repo, ["rev-parse", "HEAD"])
        let userSkill = f.repo.appendingPathComponent(".kaban/skills/dev.md")
        try "user edit\n".write(to: userSkill, atomically: true, encoding: .utf8)
        _ = try git(f.repo, ["add", ".kaban/skills/dev.md"])
        let staged = try git(f.repo, ["diff", "--cached", "--binary"])
        try f.store.database.write { db in try db.execute(sql: "DROP TRIGGER fail_project_reply") }
        let reopened = try KabanStore(path: f.database)
        try reopened.recoverProjectOperations()
        XCTAssertEqual(try reopened.getSnapshot().projects.count, 1)
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), commit)
        XCTAssertEqual(try git(f.repo, ["diff", "--cached", "--binary"]), staged)
        XCTAssertEqual(try String(contentsOf: userSkill, encoding: .utf8), "user edit\n")
        let snapshot = try reopened.getSnapshot()
        let replay = try reopened.execute(envelope, now: { XCTFail("Recovery replay read clock"); return self.at })
        XCTAssertEqual(replay.result, .ok); XCTAssertEqual(try reopened.getSnapshot(), snapshot)
    }
    func testTemplateNeverOverwritesExistingKabanOrSymlink() throws {
        let f = try fixture(), outside = f.root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.repo.appendingPathComponent(".kaban"), withDestinationURL: outside)
        XCTAssertEqual(try refusal(send(.addProject(path: f.repo.path, createTemplate: true, identity: identity), f.store)).code, "template_conflict")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertTrue(try f.store.getSnapshot().projects.isEmpty)
    }
    func testValidCommittedPipelineIsReadFromMainAndCannotUseFakeExecutor() throws {
        let f = try fixture()
        let yaml = PipelineTemplate.defaultYAML.replacingOccurrences(of: "model:            #", with: "model: explicit-model #").replacingOccurrences(of: "model:\n", with: "model: explicit-model\n")
        XCTAssertTrue(PipelineValidator.validate(yaml: yaml).isValid)
        for (name, content) in PipelineTemplate.files {
            let url = f.repo.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (name.hasSuffix("pipeline.yaml") ? yaml : content).write(to: url, atomically: true, encoding: .utf8)
        }
        _ = try git(f.repo, ["add", ".kaban"]); _ = try git(f.repo, ["commit", "-m", "Valid pipeline"])
        _ = try git(f.repo, ["switch", "-c", "feature"])
        try "not yaml".write(to: f.repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        let marker = f.root.appendingPathComponent("filter-ran")
        _ = try git(f.repo, ["config", "filter.evil.clean", "touch '\(marker.path)'; cat"])
        _ = try git(f.repo, ["config", "filter.evil.required", "true"])
        try ".kaban/** filter=evil\n".write(to: f.repo.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        let initial = try f.store.getSnapshot(), p = try add(f, template: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let snapshot = try f.store.getSnapshot(), pipeline = try XCTUnwrap(snapshot.pipelines.first)
        XCTAssertTrue(pipeline.isValid); XCTAssertTrue(pipeline.hasUncommittedEdits); XCTAssertEqual(pipeline.versionHash, PipelineContentHash.sha256(yaml))
        XCTAssertTrue(snapshot.schedulerFlags.isEmpty)
        try create(f.store, project: p.id)
        XCTAssertThrowsError(try f.store.createTask(card: .init(id: "unmanaged", projectId: p.id, title: "Must use wire", stageId: "backlog", state: .queued(nil), updatedAt: at), pipeline: XCTUnwrap(PipelineValidator.validate(yaml: yaml).config), commandId: UUID(), at: at))
        XCTAssertEqual(try refusal(send(.moveTask(taskId: "task", stage: "dev"), f.store)).code, "scheduler_blocked")
        var projection = BoardProjection(snapshot: initial)
        for event in try f.store.events(after: initial.seq).filter({ $0.seq <= snapshot.seq }) { _ = projection.apply(event) }
        assertProjection(projection, snapshot)
        XCTAssertEqual(text(try git(f.repo, ["branch", "--show-current"])), "feature")
        XCTAssertEqual(try String(contentsOf: f.repo.appendingPathComponent(".kaban/pipeline.yaml"), encoding: .utf8), "not yaml")
    }
    func testRemoveRunningProjectAtomicallyCancelsAndRejectsLateResult() throws {
        let f = try fixture(), pipeline = try ManagedEngineFixture.pipeline()
        _ = try f.store.registerProject(.init(id: "fake", name: "Fake", path: "/never-read", mascotSeed: "fake"), pipeline: pipeline, commandId: UUID(), at: at)
        _ = try f.store.setSettings(.init(maxConcurrentRuns: 2, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        try create(f.store, project: "fake")
        _ = try f.store.apply(.start("intake"), taskId: "task", commandId: UUID(), at: at)
        _ = try f.store.apply(.start("run"), taskId: "task", commandId: UUID(), at: at)
        let launch = try XCTUnwrap(f.store.pendingEffectItems().first { if case .startAgentRun = $0.effect { true } else { false } })
        let envelope = CommandEnvelope(command: .removeProject(projectId: "fake"))
        try f.store.database.write { try $0.execute(sql: "CREATE TRIGGER fail_remove_reply BEFORE INSERT ON wire_command BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        let before = try f.store.getSnapshot()
        XCTAssertThrowsError(try f.store.execute(envelope))
        XCTAssertEqual(try f.store.getSnapshot(), before)
        XCTAssertTrue(try f.store.pendingEffectItems().contains { $0.id == launch.id })
        try f.store.database.write { try $0.execute(sql: "DROP TRIGGER fail_remove_reply") }
        XCTAssertEqual(try f.store.execute(envelope).result, .ok)
        XCTAssertTrue(try f.store.getSnapshot().projects.isEmpty)
        let detail = try f.store.getTaskDetail("task")
        XCTAssertEqual(detail.task.state.status, .cancelled); XCTAssertEqual(detail.runs.count, 1)
        let pending = try f.store.pendingEffectItems()
        XCTAssertTrue(pending.contains { if case .killRun("run") = $0.effect { true } else { false } })
        XCTAssertTrue(pending.contains { if case .cleanupClone(keepBranch: true) = $0.effect { true } else { false } })
        XCTAssertThrowsError(try f.store.deliverFake(effectId: launch.id, result: .completed(summary: "late"), at: at)) { XCTAssertEqual($0 as? StoreError, .effectSuperseded) }
        let reopened = try KabanStore(path: f.database)
        XCTAssertEqual(try reopened.getTaskDetail("task"), detail)
        XCTAssertThrowsError(try reopened.registerProject(.init(id: "fake", name: "Fake", path: "/never-read", mascotSeed: "fake"), pipeline: pipeline, commandId: UUID(), at: at))
    }
    func testTemplateCompareAndSwapDoesNotOverwriteConcurrentMain() throws {
        let f = try fixture(), repository = try LocalGitRepository(path: f.repo.path)
        let plan = try repository.prepareTemplate(identity: identity, commandId: UUID())
        try "new user change".write(to: f.repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try git(f.repo, ["add", "tracked.txt"]); _ = try git(f.repo, ["commit", "-m", "Concurrent commit"])
        let head = try git(f.repo, ["rev-parse", "HEAD"])
        XCTAssertThrowsError(try repository.finishTemplate(plan)) { XCTAssertEqual(($0 as? CommandError)?.code, "git_race") }
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.repo.path + "/.kaban"))
    }
    func testProjectRecheckReceiptAndAvailabilityRollBackTogether() throws {
        let f = try fixture(), p = try add(f), before = try f.store.getSnapshot()
        try FileManager.default.moveItem(at: f.repo, to: f.root.appendingPathComponent("Moved"))
        try f.store.database.write { try $0.execute(sql: "CREATE TRIGGER fail_recheck_reply BEFORE INSERT ON wire_command BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        let envelope = CommandEnvelope(command: .recheck(scope: .project(projectId: p.id)))
        XCTAssertThrowsError(try f.store.execute(envelope)); XCTAssertEqual(try f.store.getSnapshot(), before)
        try f.store.database.write { try $0.execute(sql: "DROP TRIGGER fail_recheck_reply") }
        let reply = try f.store.execute(envelope)
        XCTAssertEqual(reply.result, .ok); XCTAssertEqual(try f.store.getSnapshot().projects.first?.availability, .missing)
        XCTAssertEqual(try KabanStore(path: f.database).execute(envelope), reply)
    }

    func testLinkedWorktreeIsDuplicateRepositoryAndConcurrentReplayRegistersOnce() throws {
        let f = try fixture(), store = f.store, clock = at
        let envelope = CommandEnvelope(command: .addProject(path: f.repo.path, createTemplate: false, identity: identity))
        let replies = ReplyCollector()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do { replies.append(.success(try store.execute(envelope, now: { clock }))) }
            catch { replies.append(.failure(error)) }
        }
        XCTAssertEqual(replies.values.count, 4)
        let first = try replies.values[0].get()
        for reply in replies.values { XCTAssertEqual(try reply.get(), first) }
        XCTAssertEqual(try store.getSnapshot().projects.count, 1)
        let worktree = f.root.appendingPathComponent("Linked")
        _ = try git(f.repo, ["worktree", "add", "-b", "linked", worktree.path])
        XCTAssertEqual(try refusal(send(.addProject(path: worktree.path, createTemplate: false, identity: identity), store)).code, "project_already_registered")
        XCTAssertEqual(try store.getSnapshot().projects.count, 1)
    }
    private final class ReplyCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [Result<CommandReply, Error>] = []
        func append(_ value: Result<CommandReply, Error>) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    }

}
