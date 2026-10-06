import Foundation
import XCTest
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class MergeQueueTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testTwoApprovedTasksDoNotWriteMainTogether() throws {
        let f = try fixture()
        let first = try enqueue(f, "alpha", "a.txt", "alpha\n")
        let second = try enqueue(f, "beta", "b.txt", "beta\n")
        try approve(f, "alpha")
        try approve(f, "beta")
        _ = try tick(f, "merge-alpha")
        let started = try task(f, "alpha")
        XCTAssertEqual(started.machine.state.status, .gating)
        XCTAssertEqual(started.machine.gatingPhase, .rebase)
        XCTAssertEqual(try task(f, "beta").machine.state.status, .queued)
        _ = try f.store.runMergePass(owner: "test", at: at, workspaceRoot: f.workspace)
        let merged = try task(f, "alpha")
        XCTAssertEqual(merged.machine.state, .done)
        XCTAssertEqual(try task(f, "beta").machine.state.status, .queued)
        XCTAssertEqual(try text(f.origin, "a.txt"), "alpha\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.origin + "/b.txt"))
        let firstTip = try sha(f, ["rev-parse", "refs/heads/main"])
        _ = try tick(f, "merge-beta")
        XCTAssertEqual(try task(f, "beta").machine.state.status, .gating)
        _ = try f.store.runMergePass(owner: "test", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try task(f, "beta").machine.state, .done)
        XCTAssertEqual(try text(f.origin, "a.txt"), "alpha\n")
        XCTAssertEqual(try text(f.origin, "b.txt"), "beta\n")
        XCTAssertEqual(try gitStatus(f, ["merge-base", "--is-ancestor", firstTip, "refs/heads/main"]), 0)
        XCTAssertEqual(try sha(f, ["rev-parse", "HEAD"]), try sha(f, ["rev-parse", "refs/heads/main"]))
        _ = (first, second)
    }

    func testMainMovedBetweenCheckAndUpdateRechecks() throws {
        let f = try fixture()
        _ = try enqueue(f, "moved", "note.txt", "from-task\n")
        try approve(f, "moved")
        _ = try tick(f, "merge-moved")
        for _ in 0..<6 {
            if try pendingFastForward(f, "moved") { break }
            if try f.store.rebaseOneMerge(owner: "test", at: at, workspaceRoot: f.workspace) { continue }
            if try f.store.runResultEffect(owner: "test", at: at) { continue }
            break
        }
        let ready = try task(f, "moved")
        XCTAssertEqual(ready.machine.gatingPhase, .fastForward)
        XCTAssertTrue(try pendingFastForward(f, "moved"))
        try "hand\n".write(toFile: f.origin + "/hand.txt", atomically: true, encoding: .utf8)
        try git(f, ["add", "hand.txt"])
        try git(f, ["commit", "-m", "hand moved main"])
        let hand = try sha(f, ["rev-parse", "refs/heads/main"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.origin + "/note.txt"))
        _ = try f.store.forwardOneMerge(owner: "test", at: at)
        XCTAssertEqual(try sha(f, ["rev-parse", "refs/heads/main"]), hand)
        XCTAssertEqual(try text(f.origin, "hand.txt"), "hand\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.origin + "/note.txt"))
        let rebased = try task(f, "moved")
        XCTAssertEqual(rebased.machine.state.status, .gating)
        XCTAssertEqual(rebased.machine.gatingPhase, .rebase)
        _ = try f.store.runMergePass(owner: "test", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try task(f, "moved").machine.state, .done)
        XCTAssertEqual(try text(f.origin, "note.txt"), "from-task\n")
        XCTAssertEqual(try text(f.origin, "hand.txt"), "hand\n")
        XCTAssertEqual(try gitStatus(f, ["merge-base", "--is-ancestor", hand, "refs/heads/main"]), 0)
    }

    func testDirtyAndIndexStateArePreserved() throws {
        let f = try fixture()
        _ = try enqueue(f, "dirty", "shared.txt", "task\n")
        _ = try enqueue(f, "waiter", "w.txt", "wait\n")
        try approve(f, "dirty")
        try approve(f, "waiter")
        _ = try tick(f, "merge-dirty")
        XCTAssertEqual(try task(f, "dirty").machine.state.status, .gating)
        try "staged\n".write(toFile: f.origin + "/shared.txt", atomically: true, encoding: .utf8)
        try git(f, ["add", "shared.txt"])
        try "staged\nunstaged\n".write(toFile: f.origin + "/shared.txt", atomically: true, encoding: .utf8)
        let cached = try gitText(f, ["diff", "--cached", "--", "shared.txt"])
        let unstaged = try gitText(f, ["diff", "--", "shared.txt"])
        let bytes = try text(f.origin, "shared.txt")
        let head = try sha(f, ["rev-parse", "refs/heads/main"])
        XCTAssertFalse(cached.isEmpty)
        XCTAssertFalse(unstaged.isEmpty)
        _ = try f.store.runMergePass(owner: "test", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try task(f, "dirty").machine.state, .blocked(.mainDirty))
        XCTAssertEqual(try task(f, "waiter").machine.state.status, .queued)
        XCTAssertEqual(try text(f.origin, "shared.txt"), bytes)
        XCTAssertEqual(try gitText(f, ["diff", "--cached", "--", "shared.txt"]), cached)
        XCTAssertEqual(try gitText(f, ["diff", "--", "shared.txt"]), unstaged)
        XCTAssertEqual(try sha(f, ["rev-parse", "refs/heads/main"]), head)
        _ = try tick(f, "merge-waiter-blocked")
        XCTAssertEqual(try task(f, "waiter").machine.state.status, .queued)
        XCTAssertNotEqual(try task(f, "waiter").machine.state.status, .gating)
        try git(f, ["reset", "--hard", "HEAD"])
        _ = try f.store.runMergePass(owner: "test", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try task(f, "dirty").machine.state, .done)
        XCTAssertEqual(try text(f.origin, "shared.txt"), "task\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.origin + "/w.txt"))
        XCTAssertEqual(try task(f, "waiter").machine.state.status, .queued)
    }

    func testCrashAfterMergeBeforeReceiptDoesNotMergeTwice() throws {
        let f = try fixture()
        _ = try enqueue(f, "crash", "crash.txt", "once\n")
        try approve(f, "crash")
        _ = try tick(f, "merge-crash")
        for _ in 0..<6 {
            if try pendingFastForward(f, "crash") { break }
            if try f.store.rebaseOneMerge(owner: "test", at: at, workspaceRoot: f.workspace) { continue }
            if try f.store.runResultEffect(owner: "test", at: at) { continue }
            break
        }
        let item = try XCTUnwrap(try f.store.pendingEffectItems().first { item in
            item.taskId == "crash" && { if case .fastForwardMerge = item.effect { return true }; return false }()
        })
        let before = try count(f)
        let lease = try XCTUnwrap(f.store.claimEffect(id: item.id, owner: "crash-test", leaseFor: 30, at: at))
        let fact = try f.store.prepareFastForward(lease: lease, at: at)
        XCTAssertEqual(fact.outcome, .merged)
        let tip = try sha(f, ["rev-parse", "refs/heads/main"])
        let commits = try count(f)
        XCTAssertGreaterThan(commits, before)
        XCTAssertEqual(try text(f.origin, "crash.txt"), "once\n")
        let again = try f.store.prepareFastForward(lease: lease, at: at)
        XCTAssertEqual(again.outcome, .merged)
        XCTAssertEqual(try count(f), commits)
        XCTAssertEqual(try sha(f, ["rev-parse", "refs/heads/main"]), tip)
        let receipts = try f.store.recoverEffectExecution(at: at, reclaimUnexpired: true)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(try task(f, "crash").machine.state, .done)
        XCTAssertEqual(try count(f), commits)
        XCTAssertEqual(try sha(f, ["rev-parse", "refs/heads/main"]), tip)
        _ = try f.store.runMergePass(owner: "test", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try count(f), commits)
        XCTAssertEqual(try sha(f, ["rev-parse", "refs/heads/main"]), tip)
        XCTAssertEqual(try text(f.origin, "crash.txt"), "once\n")
    }

    func testConflictLoopAndCancelOfWaitingMerge() throws {
        let f = try fixture()
        _ = try enqueue(f, "conflict", "shared.txt", "task\n")
        _ = try enqueue(f, "waiting", "other.txt", "other\n")
        try "main\n".write(toFile: f.origin + "/shared.txt", atomically: true, encoding: .utf8)
        try git(f, ["add", "shared.txt"])
        try git(f, ["commit", "-m", "main diverges"])
        try approve(f, "conflict")
        try approve(f, "waiting")
        _ = try tick(f, "merge-conflict")
        XCTAssertEqual(try task(f, "conflict").machine.state.status, .gating)
        XCTAssertEqual(try task(f, "waiting").machine.state.status, .queued)
        _ = try f.store.runMergePass(owner: "test", at: at, workspaceRoot: f.workspace)
        let returned = try task(f, "conflict")
        XCTAssertEqual(returned.machine.stageId.rawValue, "dev")
        XCTAssertEqual(returned.machine.state.status, .queued)
        XCTAssertEqual(returned.machine.returnReason, .mergeConflict)
        XCTAssertTrue(returned.machine.pendingPrompt.contains { addition in
            if case .mergeConflict(let files) = addition { return files.contains("shared.txt") }
            return false
        })
        XCTAssertEqual(try text(f.origin, "shared.txt"), "main\n")
        XCTAssertEqual(try task(f, "waiting").machine.state.status, .queued)
        _ = try apply(f, "waiting", .cancel(keepBranch: false))
        XCTAssertEqual(try task(f, "waiting").machine.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.origin + "/other.txt"))
        _ = try tick(f, "conflict-run-2")
        XCTAssertEqual(try task(f, "conflict").machine.state, .running)
        _ = try apply(f, "conflict", .completeStage(try runId(f, "conflict"), summary: "fixed"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        _ = try tick(f, "conflict-review-2")
        XCTAssertEqual(try task(f, "conflict").machine.state, .waitingHuman(.review))
        _ = try apply(f, "conflict", .approve)
        _ = try tick(f, "conflict-merge-2")
        _ = try f.store.runMergePass(owner: "test", at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try task(f, "conflict").machine.state, .waitingHuman(.conflictLimit))
        XCTAssertEqual(try text(f.origin, "shared.txt"), "main\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.origin + "/other.txt"))
        XCTAssertEqual(try task(f, "waiting").machine.state, .cancelled)
    }

    func testDaemonPrintsOneMergePassTwice() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the merge launch") }
        let f = try fixture()
        _ = try enqueue(f, "once", "once.txt", "once\n")
        try approve(f, "once")
        _ = try tick(f, "merge-once")
        XCTAssertEqual(try task(f, "once").machine.state.status, .gating)
        let first = try runDaemon(executable, database: f.path, workspace: f.workspace)
        let second = try runDaemon(executable, database: f.path, workspace: f.workspace)
        XCTAssertEqual(first.exit, 0, first.stderr)
        XCTAssertEqual(second.exit, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        let tip = try sha(f, ["rev-parse", "refs/heads/main"])
        XCTAssertTrue(first.stderr.contains("merge once ff \(tip)"))
        XCTAssertEqual(try text(f.origin, "once.txt"), "once\n")
        XCTAssertEqual(try task(f, "once").machine.state, .done)
        XCTAssertEqual(try count(f), 2)
        if let root = ProcessInfo.processInfo.environment["KABAN_PROCESS_EVIDENCE"].map(URL.init(fileURLWithPath:)) {
            try first.stderr.write(to: root.appendingPathComponent("be-17-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-17-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    private struct Fixture { var root: URL; var workspace: String; var path: String; var store: KabanStore; var origin: String }

    private func pipeline() -> String {
        """
        version: 1
        board: {max_waiting_human: 4, bounce_limit_total: 5, max_runs_per_task: 12}
        stages:
          - {id: backlog, kind: queue, on_success: dev}
          - id: dev
            kind: agent
            wip: 2
            agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
            gates: ["/usr/bin/true"]
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review
          - {id: review, kind: human, wip: 2, on_success: merge}
          - id: merge
            kind: merge
            wip: 1
            on_conflict: {stage: dev, limit: 1}
            on_success: done
          - {id: done, kind: terminal}
        """
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-merge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        try pipeline().write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try "skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try "base\n".write(to: repo.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["config", "user.name", "Merge Test"])
        try git(repo, ["config", "user.email", "merge@example.test"])
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "Pipeline"])
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result, .ok)
        _ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        return Fixture(root: root, workspace: root.appendingPathComponent("workspaces").path, path: path, store: store, origin: repo.path)
    }

    @discardableResult
    private func enqueue(_ f: Fixture, _ id: TaskID, _ name: String, _ contents: String) throws -> TaskCloneSnapshot {
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let reply = try f.store.execute(.init(command: .createTask(projectId: project, title: id.rawValue, body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), now: { self.at }, makeTaskID: { id })
        XCTAssertEqual(reply.result, .taskCreated(id))
        _ = try tick(f, id.rawValue + "-admit")
        let started = try tick(f, id.rawValue + "-run")
        XCTAssertEqual(started.transitions.last?.task.machine.state, .running)
        let clone = try f.store.prepareTaskClone(taskId: id, at: at, workspaceRoot: f.workspace)
        try contents.write(to: URL(fileURLWithPath: clone.clonePath).appendingPathComponent(name), atomically: true, encoding: .utf8)
        _ = try apply(f, id, .completeStage(try runId(f, id), summary: "Dev done"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        _ = try tick(f, id.rawValue + "-review")
        XCTAssertEqual(try task(f, id).machine.state, .waitingHuman(.review))
        return clone
    }

    private func approve(_ f: Fixture, _ id: TaskID) throws {
        _ = try apply(f, id, .approve)
        XCTAssertEqual(try task(f, id).machine.stageId.rawValue, "merge")
        XCTAssertEqual(try task(f, id).machine.state.status, .queued)
    }

    private func tick(_ f: Fixture, _ run: String) throws -> TickReceipt {
        try f.store.tick(tickId: UUID(), runId: RunID(rawValue: run), at: at)
    }

    private func task(_ f: Fixture, _ id: TaskID) throws -> DurableTask {
        try XCTUnwrap(f.store.snapshot().tasks.first { $0.card.id == id })
    }

    private func runId(_ f: Fixture, _ id: TaskID) throws -> RunID {
        try XCTUnwrap(task(f, id).machine.currentRunId ?? task(f, id).machine.lastRunId)
    }

    private func apply(_ f: Fixture, _ id: TaskID, _ command: DurableTaskCommand) throws -> DurableReceipt {
        try f.store.apply(command, taskId: id, commandId: UUID(), at: at)
    }

    private func pendingFastForward(_ f: Fixture, _ id: TaskID) throws -> Bool {
        try f.store.pendingEffectItems().contains { item in
            item.taskId == id && { if case .fastForwardMerge = item.effect { return true }; return false }()
        }
    }

    private func text(_ root: String, _ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name), encoding: .utf8)
    }

    private func sha(_ f: Fixture, _ args: [String]) throws -> String {
        try gitText(f, args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func count(_ f: Fixture) throws -> Int {
        Int(try sha(f, ["rev-list", "--count", "refs/heads/main"])) ?? -1
    }

    @discardableResult
    private func gitStatus(_ f: Fixture, _ args: [String]) throws -> Int32 {
        try gitStatus(URL(fileURLWithPath: f.origin), args)
    }

    @discardableResult
    private func gitStatus(_ repo: URL, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.environment = DaemonGit.processEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func git(_ f: Fixture, _ args: [String]) throws { try git(URL(fileURLWithPath: f.origin), args) }

    private func git(_ repo: URL, _ args: [String]) throws {
        let status = try gitStatus(repo, args)
        XCTAssertEqual(status, 0, "\(args)")
    }

    private func gitText(_ f: Fixture, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", f.origin] + args
        process.environment = DaemonGit.processEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(args) \(String(decoding: (process.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private struct DaemonOutput { var exit: Int32; var stderr: String }
    private func runDaemon(_ binary: URL, database: String, workspace: String) throws -> DaemonOutput {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--merge-pass", "--stdio", "--workspaces", workspace, "--database", database]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return DaemonOutput(exit: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
