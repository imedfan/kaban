import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class TaskCloneTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let yaml = """
    version: 1
    board: {max_waiting_human: 2, max_runs_per_task: 20}
    stages:
      - {id: backlog, kind: queue, on_success: dev}
      - id: dev
        kind: agent
        wip: 4
        agent: {model: explicit, skill: .kaban/dev.md, workspace: fresh-readonly}
        retry: {max_attempts: 3, backoff: [30s]}
        on_success: inspect
      - id: inspect
        kind: agent
        wip: 4
        agent: {model: composer-fast, skill: .kaban/dev.md}
        on_success: check
      - {id: check, kind: gate, wip: 2, gates: ["echo check"], on_success: review}
      - {id: review, kind: human, wip: 2, on_success: merge}
      - {id: merge, kind: merge, gates: ["echo merge"], on_success: done}
      - {id: done, kind: terminal}

    """

    struct Fixture { let root: URL; let workspace: String; let path: String; var store: KabanStore; let origin: String }

    func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-clone-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        try yaml.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try "skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["config", "user.name", "Clone Test"])
        try git(repo, ["config", "user.email", "clone@example.test"])
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "Pipeline"])
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result, .ok)
        _ = try store.setSettings(.init(maxConcurrentRuns: 2, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        let workspace = root.appendingPathComponent("workspaces").path
        return Fixture(root: root, workspace: workspace, path: path, store: store, origin: repo.path)
    }

    func git(_ repo: URL, _ args: [String]) throws {
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

    func text(_ repo: String, _ args: [String]) throws -> String {
        let process = try gitProcess(repo, args)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(args)")
        return try output(process)
    }

    func gitStatus(_ repo: String, _ args: [String]) throws -> Int32 {
        let process = try gitProcess(repo, args)
        process.waitUntilExit()
        return process.terminationStatus
    }

    func gitProcess(_ repo: String, _ args: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        process.environment = DaemonGit.processEnvironment
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    func output(_ process: Process) throws -> String {
        let pipe = try XCTUnwrap(process.standardOutput as? Pipe)
        var value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    struct OriginMark: Equatable { var head: String; var main: String; var status: String; var config: Data }

    func mark(_ origin: String) throws -> OriginMark {
        OriginMark(head: try text(origin, ["rev-parse", "HEAD"]), main: try text(origin, ["rev-parse", "refs/heads/main"]),
                   status: try text(origin, ["status", "--porcelain"]), config: try Data(contentsOf: URL(fileURLWithPath: origin + "/.git/config")))
    }

    func launch(_ f: Fixture, _ id: TaskID) throws -> RunID {
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let reply = try f.store.execute(.init(command: .createTask(projectId: project, title: id.rawValue, body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), now: { self.at }, makeTaskID: { id })
        XCTAssertEqual(reply.result, .taskCreated(id))
        _ = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-admit"), at: at)
        let started = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-run"), at: at)
        XCTAssertEqual(started.transitions.last?.task.machine.state, .running)
        return try XCTUnwrap(started.transitions.last?.task.machine.currentRunId)
    }

    func task(_ f: Fixture, _ id: TaskID) throws -> DurableTask {
        try XCTUnwrap(f.store.snapshot().tasks.first { $0.card.id == id })
    }

    func testPathGuardRejectsForeignAndPrefixPaths() {
        XCTAssertThrowsError(try TaskClone.authorizeDeletion(candidate: "/repo", recorded: "/repo", workspaceRoot: "/ws", origin: "/repo")) { XCTAssertEqual($0 as? TaskClone.Failure, .originProtected) }
        XCTAssertThrowsError(try TaskClone.authorizeDeletion(candidate: "/ws-evil/task", recorded: "/ws-evil/task", workspaceRoot: "/ws", origin: "/repo")) { XCTAssertEqual($0 as? TaskClone.Failure, .outsideWorkspace) }
        XCTAssertThrowsError(try TaskClone.authorizeDeletion(candidate: "/ws/other", recorded: "/ws/p/task", workspaceRoot: "/ws", origin: "/repo")) { XCTAssertEqual($0 as? TaskClone.Failure, .foreignPath) }
        XCTAssertNoThrow(try TaskClone.authorizeDeletion(candidate: "/ws/p/task", recorded: "/ws/p/task", workspaceRoot: "/ws", origin: "/repo"))
    }

    func testParallelClonesStayApartAndLeaveTheUserCheckoutUntouched() throws {
        let f = try fixture()
        let before = try mark(f.origin)
        let firstRun = try launch(f, "alpha")
        let secondRun = try launch(f, "beta")
        let first = try f.store.prepareTaskClone(taskId: "alpha", at: at, workspaceRoot: f.workspace)
        let second = try f.store.prepareTaskClone(taskId: "beta", at: at, workspaceRoot: f.workspace)
        XCTAssertNotEqual(first.clonePath, second.clonePath)
        XCTAssertNotEqual(first.branch, second.branch)
        XCTAssertNotEqual(first.freshPath, second.freshPath)
        XCTAssertNotEqual(first.portStart, second.portStart)
        let firstGit = try text(first.clonePath, ["rev-parse", "--absolute-git-dir"])
        let secondGit = try text(second.clonePath, ["rev-parse", "--absolute-git-dir"])
        let originGit = try text(f.origin, ["rev-parse", "--absolute-git-dir"])
        let firstFresh = try text(try XCTUnwrap(first.freshPath), ["rev-parse", "--absolute-git-dir"])
        XCTAssertNotEqual(firstGit, secondGit)
        XCTAssertNotEqual(firstGit, originGit)
        XCTAssertNotEqual(firstGit, firstFresh)
        XCTAssertNotEqual(try text(first.clonePath, ["config", "--get", "remote.origin.pushurl"]), "")
        XCTAssertEqual(try text(first.clonePath, ["config", "--get", "remote.origin.pushurl"]), "kaban-no-push")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.derivedDataPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.origin + "/DerivedData"))
        XCTAssertEqual(try mark(f.origin), before)
        XCTAssertEqual(try task(f, "alpha").machine.currentRunId, firstRun)
        XCTAssertEqual(try task(f, "beta").machine.currentRunId, secondRun)
        let again = try f.store.prepareTaskClone(taskId: "alpha", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(again.clonePath, first.clonePath)
        XCTAssertEqual(try text(first.clonePath, ["rev-parse", "--absolute-git-dir"]), firstGit)
    }

    func testPartialCloneReusesTheSamePathAndDoesNotStartAnotherRun() throws {
        let f = try fixture()
        let run = try launch(f, "task")
        let reserved = try f.store.reserveTaskClone(taskId: "task", at: at, workspaceRoot: f.workspace)
        try FileManager.default.createDirectory(atPath: reserved.clonePath, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: URL(fileURLWithPath: reserved.clonePath + "/junk"))
        let before = try mark(f.origin)
        let ready = try f.store.prepareTaskClone(taskId: "task", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(ready.clonePath, reserved.clonePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reserved.clonePath + "/junk"))
        XCTAssertEqual(try task(f, "task").machine.currentRunId, run)
        XCTAssertEqual(try f.store.pendingEffectItems().filter { if case .startAgentRun = $0.effect { true } else { false } }.count, 1)
        XCTAssertEqual(try mark(f.origin), before)
        let reopened = try KabanStore(path: f.path)
        let repeated = try reopened.prepareTaskClone(taskId: "task", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(repeated.clonePath, reserved.clonePath)
        XCTAssertEqual(try reopened.snapshot().tasks.first { $0.card.id == "task" }?.machine.currentRunId, run)
    }

    func testCancelArchivesByChoiceAndCleanupRefusesAForeignPath() throws {
        let f = try fixture()
        let before = try mark(f.origin)
        _ = try launch(f, "kept")
        _ = try launch(f, "dropped")
        let kept = try f.store.prepareTaskClone(taskId: "kept", at: at, workspaceRoot: f.workspace)
        let keptURL = URL(fileURLWithPath: kept.clonePath)
        try Data("Committed result\n".utf8).write(to: keptURL.appendingPathComponent("result.txt"))
        try git(keptURL, ["add", "result.txt"])
        try git(keptURL, ["-c", "user.name=Kaban QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Task result"])
        let fetchHead = URL(fileURLWithPath: f.origin + "/.git/FETCH_HEAD")
        let fetchHeadBefore = Data("Existing user fetch state\n".utf8)
        try fetchHeadBefore.write(to: fetchHead)
        let resultTip = try text(kept.clonePath, ["rev-parse", "HEAD"])
        XCTAssertNotEqual(try gitStatus(f.origin, ["cat-file", "-e", resultTip]), 0)
        let dropped = try f.store.prepareTaskClone(taskId: "dropped", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try f.store.execute(.init(command: .cancelTask(taskId: "kept", keepBranch: true)), now: { at }).result, .ok)
        XCTAssertEqual(try f.store.execute(.init(command: .cancelTask(taskId: "dropped", keepBranch: false)), now: { at }).result, .ok)
        let effects = try f.store.pendingEffectItems().filter { if case .cleanupClone = $0.effect { true } else { false } }
        XCTAssertEqual(effects.count, 2)
        for effect in effects {
            _ = try f.store.cleanupTaskClone(effectId: effect.id, owner: "cleaner", at: at)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.clonePath))
        XCTAssertEqual(try text(f.origin, ["rev-parse", "HEAD"]), before.head)
        XCTAssertEqual(try text(f.origin, ["rev-parse", "refs/heads/main"]), before.main)
        XCTAssertEqual(try text(f.origin, ["status", "--porcelain"]), "")
        XCTAssertEqual(try text(f.origin, ["rev-parse", "refs/kaban/archive/kept"]), resultTip)
        XCTAssertEqual(try text(f.origin, ["show", "refs/kaban/archive/kept:result.txt"]), "Committed result")
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.clonePath))
        XCTAssertEqual(try Data(contentsOf: fetchHead), fetchHeadBefore)
        XCTAssertEqual(try text(f.origin, ["for-each-ref", "--format=%(refname)", "refs/heads/"]), "refs/heads/main")
        XCTAssertNotEqual(try gitStatus(f.origin, ["show-ref", "--verify", "refs/kaban/archive/dropped"]), 0)
        let keptEffect = try XCTUnwrap(effects.first { if case .cleanupClone(true) = $0.effect { true } else { false } })
        var tampered = try f.store.database.read { db in try XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM task_clone WHERE task_id = ?", arguments: ["kept"])) }
        var record = try JSONDecoder().decode(TaskCloneRecord.self, from: tampered)
        record.clonePath = f.origin
        record.phase = "ready"
        tampered = try JSONEncoder().encode(record)
        try f.store.database.write { db in
            try db.execute(sql: "UPDATE task_clone SET payload = ? WHERE task_id = ?", arguments: [tampered, "kept"])
            try db.execute(sql: "UPDATE effect SET status = 'pending', lease_id = NULL, external_fact = NULL, result = NULL, receipt = NULL WHERE id = ?", arguments: [keptEffect.id])
        }
        XCTAssertThrowsError(try f.store.cleanupTaskClone(effectId: keptEffect.id, owner: "cleaner", at: at)) { XCTAssertEqual($0 as? TaskClone.Failure, .originProtected) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.origin + "/.git"))
        XCTAssertEqual(try text(f.origin, ["rev-parse", "refs/heads/main"]), before.main)
    }

    func testDaemonReopenPrintsTheSameCloneAndDoesNotCreateAnother() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the clone launch") }
        let f = try fixture()
        _ = try launch(f, "task")
        let ready = try f.store.prepareTaskClone(taskId: "task", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try f.store.execute(.init(commandId: UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!, command: .pauseTask(taskId: "task")), now: { at }).result, .ok)
        _ = try f.store.execute(.init(command: .pauseAll), now: { at })
        let first = try runDaemon(executable, database: f.path, workspaces: f.workspace)
        let second = try runDaemon(executable, database: f.path, workspaces: f.workspace)
        XCTAssertEqual(first.exit, 0, first.stderr)
        XCTAssertEqual(second.exit, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        XCTAssertTrue(first.stderr.contains("clone ready task branch kaban/task-task"))
        XCTAssertTrue(first.stderr.contains("clone origin-clean task"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.clonePath + "/.git"))
        if let dir = ProcessInfo.processInfo.environment["KABAN_CLONE_EVIDENCE"] {
            let root = URL(fileURLWithPath: dir, isDirectory: true)
            try first.stderr.write(to: root.appendingPathComponent("be-06-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-06-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    struct DaemonOutput { var exit: Int32; var stderr: String }

    func runDaemon(_ binary: URL, database: String, workspaces: String) throws -> DaemonOutput {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--clone-pass", "--workspaces", workspaces, "--stdio", "--database", database]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return DaemonOutput(exit: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
