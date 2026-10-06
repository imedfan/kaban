import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore
#if canImport(Darwin)
import Darwin
#endif

final class ProcessControlTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    func pipeline(stall: String, wall: String) -> String {
        """
        version: 1
        board: {max_waiting_human: 2, max_runs_per_task: 20}
        stages:
          - {id: backlog, kind: queue, on_success: dev}
          - id: dev
            kind: agent
            wip: 4
            agent: {model: explicit, skill: .kaban/dev.md}
            retry: {max_attempts: 3, backoff: [30s, 2m]}
            timeouts: {stall: \(stall), wall: \(wall)}
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
    }

    struct Fixture { let root: URL; let workspace: String; let path: String; var store: KabanStore; let origin: String }

    func fixture(stall: String = "10m", wall: String = "60m") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-proc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        try pipeline(stall: stall, wall: wall).write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try "skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["config", "user.name", "Process Test"])
        try git(repo, ["config", "user.email", "process@example.test"])
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "Pipeline"])
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result, .ok)
        _ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        let workspace = root.appendingPathComponent("workspaces").path
        let built = Fixture(root: root, workspace: workspace, path: path, store: store, origin: repo.path)
        addTeardownBlock {
            for record in (try? built.store.agentProcesses()) ?? [] where record.processGroup > 1 {
                _ = kill(-record.processGroup, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(record.pid, &status, WNOHANG)
            }
        }
        return built
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

    func apply(_ f: Fixture, _ id: TaskID, _ command: DurableTaskCommand, at when: Date) throws -> DurableReceipt {
        try f.store.apply(command, taskId: id, commandId: UUID(), at: when)
    }

    func script(_ f: Fixture, _ name: String, _ body: String) throws -> String {
        let url = f.root.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func pass(_ f: Fixture, at when: Date, runner: String?, arguments: [String] = []) throws -> [String] {
        try f.store.runProcessPass(owner: "test", at: when, workspaceRoot: f.workspace, runner: runner, runnerArguments: arguments)
    }

    func until(_ f: Fixture, contains needle: String, runner: String, arguments: [String]) throws -> [String] {
        let deadline = Date().addingTimeInterval(2)
        var lines: [String] = []
        while Date() < deadline {
            lines = try pass(f, at: at, runner: runner, arguments: arguments)
            if lines.contains(where: { $0.contains(needle) }) { return lines }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return lines
    }

    func testTechnicalExitDoesNotFinishTheStage() throws {
        let f = try fixture()
        let loud = try script(f, "loud.sh", "echo activity\nexit 0\n")
        let quiet = try script(f, "quiet.sh", "exit 0\n")
        let waiter = try script(f, "wait.sh", "flag=$1\nwhile [ ! -e \"$flag\" ]; do\n  /bin/sleep 0.05\ndone\necho activity\n")
        let run = try launch(f, "loud")
        let lines = try until(f, contains: "no_final_call", runner: "/bin/sh", arguments: [loud])
        XCTAssertTrue(lines.contains("process group \(run.rawValue) started"))
        XCTAssertTrue(lines.contains("process exit \(run.rawValue) no_final_call"))
        let loudTask = try task(f, "loud")
        XCTAssertEqual(loudTask.machine.state, .retryWait(.noFinalCall))
        XCTAssertEqual(loudTask.machine.stageId.rawValue, "dev")
        XCTAssertEqual(loudTask.machine.attemptsUsed, 1)
        XCTAssertNotEqual(loudTask.machine.state.status, .done)
        let recorded = try XCTUnwrap(try f.store.agentProcesses().first { $0.runId == run })
        XCTAssertNil(recorded.sessionId)
        XCTAssertFalse(recorded.startId.isEmpty)
        XCTAssertEqual(recorded.pid, recorded.processGroup)
        XCTAssertGreaterThan(recorded.pid, 1)
        XCTAssertGreaterThan(fileSize(recorded.stdoutPath), 0)

        let silentRun = try launch(f, "silent")
        let silentLines = try until(f, contains: "silent-exit", runner: "/bin/sh", arguments: [quiet])
        XCTAssertTrue(silentLines.contains("process exit \(silentRun.rawValue) silent-exit"))
        XCTAssertFalse(silentLines.contains("process exit \(silentRun.rawValue) no_final_call"))
        let silentTask = try task(f, "silent")
        XCTAssertEqual(silentTask.machine.state, .retryWait(.silentExit))
        XCTAssertEqual(silentTask.machine.attemptsUsed, 0)
        XCTAssertEqual(silentTask.machine.runsSinceHuman, 0)
        XCTAssertEqual(try f.store.agentProcesses().first { $0.runId == silentRun }?.exitClass, "silent_exit")

        let flag = f.root.appendingPathComponent("release").path
        let gated = try launch(f, "gated")
        let started = Date()
        _ = try pass(f, at: at, runner: "/bin/sh", arguments: [waiter, flag])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        _ = try apply(f, "gated", .completeStage(gated, summary: "summary"), at: at)
        FileManager.default.createFile(atPath: flag, contents: Data())
        try waitForZombie(try XCTUnwrap(try f.store.agentProcesses().first { $0.runId == gated }).pid)
        _ = try pass(f, at: at, runner: nil)
        let gatedTask = try task(f, "gated")
        XCTAssertEqual(gatedTask.machine.state, .gating)
        XCTAssertEqual(gatedTask.machine.stageId.rawValue, "dev")
        XCTAssertNotEqual(gatedTask.machine.state.status, .done)
        XCTAssertEqual(try f.store.agentProcesses().first { $0.runId == gated }?.exitClass, "ignored_late")
    }

    func testChargesSkipManualStopRestartAuthLimitAndSubstitution() throws {
        let f = try fixture()
        let paused = try finish(f, "paused", .pause)
        XCTAssertEqual(paused.receipt.task.machine.state, .paused)
        XCTAssertEqual(try summary(f, "paused", paused.run).endReason, .pausedByHuman)
        XCTAssertFalse(try summary(f, "paused", paused.run).countsTowardLimits)
        try release(f, "paused")

        let moved = try finish(f, "moved") { _ in .move(StageID(rawValue: "backlog")) }
        XCTAssertEqual(moved.receipt.task.machine.stageId.rawValue, "backlog")
        XCTAssertEqual(moved.receipt.task.machine.attemptsUsed, 0)
        XCTAssertEqual(moved.receipt.task.machine.runsSinceHuman, 0)
        try release(f, "moved")

        let cancelled = try finish(f, "cancelled") { _ in .cancel(keepBranch: false) }
        XCTAssertEqual(cancelled.receipt.task.machine.state, .cancelled)

        let restarted = try finish(f, "restarted", .daemonRestarted)
        XCTAssertEqual(restarted.receipt.task.machine.state, .retryWait(.daemonRestart))
        XCTAssertEqual(try summary(f, "restarted", restarted.run).endReason, .daemonRestart)
        XCTAssertFalse(try summary(f, "restarted", restarted.run).countsTowardLimits)
        try release(f, "restarted")

        let limited = try finish(f, "limited") { .runFailed($0, .rateLimit) }
        XCTAssertEqual(limited.receipt.task.machine.state, .retryWait(.rateLimit))
        XCTAssertEqual(try summary(f, "limited", limited.run).endReason, .rateLimit)
        XCTAssertFalse(try summary(f, "limited", limited.run).countsTowardLimits)
        try release(f, "limited")

        let usage = try finish(f, "usage") { .runFailed($0, .usageExhausted(.cm)) }
        XCTAssertEqual(usage.receipt.task.machine.state, .queued(.quotaCm))
        try release(f, "usage")

        let auth = try finish(f, "auth") { .runFailed($0, .runnerAuth) }
        XCTAssertEqual(auth.receipt.task.machine.state, .retryWait(.runnerAuth))
        XCTAssertEqual(try summary(f, "auth", auth.run).endReason, .runnerAuth)
        XCTAssertFalse(try summary(f, "auth", auth.run).countsTowardLimits)
        try release(f, "auth")

        let swapped = try finish(f, "swapped") { .modelMismatch(runId: $0, requested: "explicit", actual: "other", fallback: nil) }
        XCTAssertEqual(swapped.receipt.task.machine.state, .waitingHuman(.modelSubstituted))
        XCTAssertEqual(try summary(f, "swapped", swapped.run).endReason, .modelSubstituted)
        XCTAssertFalse(try summary(f, "swapped", swapped.run).countsTowardLimits)
        try release(f, "swapped")

        for item in [paused, moved, cancelled, restarted, limited, usage, auth, swapped] {
            XCTAssertEqual(item.receipt.task.machine.attemptsUsed, 0, item.receipt.task.card.id.rawValue)
            XCTAssertEqual(item.receipt.task.machine.runsSinceHuman, 0, item.receipt.task.card.id.rawValue)
        }
    }

    func testCrashRetriesUseThirtySecondsThenTwoMinutes() throws {
        let f = try fixture()
        let run = try launch(f, "retry")
        let first = try apply(f, "retry", .runFailed(run, .crash), at: at)
        XCTAssertEqual(first.task.machine.state, .retryWait(.crash))
        XCTAssertEqual(first.task.machine.attemptsUsed, 1)
        XCTAssertEqual(first.task.machine.runsSinceHuman, 1)
        XCTAssertEqual(first.task.card.retryAt, at.addingTimeInterval(30))
        let secondAt = at.addingTimeInterval(30)
        let secondRun = RunID(rawValue: "retry-2")
        XCTAssertEqual(try apply(f, "retry", .start(secondRun), at: secondAt).task.machine.state, .running)
        let second = try apply(f, "retry", .runFailed(secondRun, .crash), at: secondAt)
        XCTAssertEqual(second.task.machine.attemptsUsed, 2)
        XCTAssertEqual(second.task.card.retryAt, secondAt.addingTimeInterval(120))
        let thirdAt = secondAt.addingTimeInterval(120)
        let thirdRun = RunID(rawValue: "retry-3")
        XCTAssertEqual(try apply(f, "retry", .start(thirdRun), at: thirdAt).task.machine.state, .running)
        let third = try apply(f, "retry", .runFailed(thirdRun, .crash), at: thirdAt)
        XCTAssertEqual(third.task.machine.state, .waitingHuman(.retriesExhausted))
        XCTAssertEqual(third.task.machine.attemptsUsed, 3)
        XCTAssertEqual(third.task.machine.stageId.rawValue, "dev")
    }

    func testTimeoutDoesNotBlockThePass() throws {
        // Validator accepts 1m…2h for stall and 1m…24h for wall, and stall cannot exceed wall.
        // The child sleeps 30 real seconds; the pass clock moves without waiting.
        try assertTimeout(stall: "1m", wall: "1h", kind: "stall", state: .retryWait(.stallTimeout), advance: 60)
        try assertTimeout(stall: "1m", wall: "1m", kind: "wall", state: .retryWait(.wallTimeout), advance: 60)
    }

    func assertTimeout(stall: String, wall: String, kind: String, state: TaskState, advance: TimeInterval) throws {
        let f = try fixture(stall: stall, wall: wall)
        let run = try launch(f, "sleep")
        let started = Date()
        let first = try pass(f, at: at, runner: "/bin/sleep", arguments: ["30"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, first.joined(separator: "\n"))
        XCTAssertTrue(first.contains("process group \(run.rawValue) started"))
        XCTAssertFalse(first.contains("timeout"))
        let record = try XCTUnwrap(try f.store.agentProcesses().first { $0.runId == run })
        XCTAssertTrue(ProcessGroup.isAlive(record.pid))
        XCTAssertEqual(try task(f, "sleep").machine.attemptsUsed, 0)
        let again = Date()
        let second = try pass(f, at: at.addingTimeInterval(advance), runner: nil)
        XCTAssertLessThan(Date().timeIntervalSince(again), 5, second.joined(separator: "\n"))
        XCTAssertTrue(second.contains("process timeout \(run.rawValue) \(kind)"))
        let finished = try task(f, "sleep")
        XCTAssertEqual(finished.machine.state, state)
        XCTAssertEqual(finished.machine.stageId.rawValue, "dev")
        XCTAssertEqual(finished.machine.attemptsUsed, 1)
        XCTAssertEqual(finished.machine.runsSinceHuman, 1)
        try waitUntilIdle(record.pid)
        XCTAssertFalse(isRunning(record.pid))
    }

    func testPauseStopsOnlyThatTaskGroupIncludingDescendants() throws {
        let f = try fixture()
        let script = try script(f, "child.sh", """
        /bin/sleep 30 &
        echo $! > child.pid
        wait
        """)
        let first = try launch(f, "one")
        let second = try launch(f, "two")
        _ = try pass(f, at: at, runner: "/bin/sh", arguments: [script])
        let records = try f.store.agentProcesses()
        let leaderA = try XCTUnwrap(records.first { $0.runId == first })
        let leaderB = try XCTUnwrap(records.first { $0.runId == second })
        XCTAssertNotEqual(leaderA.processGroup, leaderB.processGroup)
        let childA = try waitForPid(leaderA.workingDirectory + "/child.pid")
        let childB = try waitForPid(leaderB.workingDirectory + "/child.pid")
        XCTAssertEqual(ProcessGroup.processGroup(of: childA), leaderA.processGroup)
        XCTAssertEqual(ProcessGroup.processGroup(of: childB), leaderB.processGroup)
        _ = try f.store.execute(.init(command: .pauseTask(taskId: "one")), now: { at })
        var stored = try processRecord(f, first)
        let savedGroup = stored.processGroup
        stored.processGroup = leaderB.processGroup
        try writeProcess(f, stored)
        XCTAssertThrowsError(try pass(f, at: at, runner: nil)) { XCTAssertEqual($0 as? ProcessGroup.Failure, .foreignGroup) }
        XCTAssertTrue(isRunning(leaderA.pid))
        XCTAssertTrue(isRunning(childA))
        XCTAssertTrue(isRunning(leaderB.pid))
        XCTAssertTrue(isRunning(childB))
        stored.processGroup = savedGroup
        try writeProcess(f, stored)
        let kill = try XCTUnwrap(try effects(f).first { if case .killRun(first) = $0.effect { true } else { false } })
        try resetEffect(f, kill.id)
        let started = Date()
        let lines = try pass(f, at: at, runner: nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(lines.contains("process group \(first.rawValue) stopped"))
        try waitUntilIdle(leaderA.pid)
        try waitUntilIdle(childA)
        XCTAssertFalse(isRunning(leaderA.pid))
        XCTAssertFalse(isRunning(childA))
        XCTAssertTrue(isRunning(leaderB.pid))
        XCTAssertTrue(isRunning(childB))
        XCTAssertEqual(try task(f, "one").machine.attemptsUsed, 0)
        XCTAssertEqual(try task(f, "one").machine.runsSinceHuman, 0)
        try resetEffect(f, kill.id)
        _ = try pass(f, at: at, runner: nil)
        XCTAssertTrue(isRunning(leaderB.pid))
        XCTAssertTrue(isRunning(childB))
        XCTAssertEqual(try task(f, "one").machine.state, .paused)
    }

    func testNoFinalCallAndGateFailureKeepTheCloneWhileCrashRollsBack() throws {
        let f = try fixture()
        let before = try mark(f.origin)
        let loud = try script(f, "loud.sh", "echo activity\nexit 0\n")
        let crash = try script(f, "crash.sh", "exit 1\n")
        _ = try launch(f, "keep")
        let kept = try f.store.prepareTaskClone(taskId: "keep", at: at, workspaceRoot: f.workspace)
        try "keep\n".write(toFile: kept.clonePath + "/keep.txt", atomically: true, encoding: .utf8)
        _ = try until(f, contains: "no_final_call", runner: "/bin/sh", arguments: [loud])
        XCTAssertEqual(try String(contentsOfFile: kept.clonePath + "/keep.txt", encoding: .utf8), "keep\n")
        XCTAssertNotEqual(try gitStatus(kept.clonePath, ["show-ref", "--verify", "refs/kaban/wip/keep-run"]), 0)
        XCTAssertEqual(try task(f, "keep").machine.state, .retryWait(.noFinalCall))

        let gated = try launch(f, "gate")
        let gateClone = try f.store.prepareTaskClone(taskId: "gate", at: at, workspaceRoot: f.workspace)
        try "gate\n".write(toFile: gateClone.clonePath + "/gate.txt", atomically: true, encoding: .utf8)
        _ = try apply(f, "gate", .completeStage(gated, summary: "summary"), at: at)
        let failed = try apply(f, "gate", .gatesFailed(output: "red"), at: at)
        _ = try pass(f, at: at, runner: nil)
        XCTAssertEqual(failed.task.machine.state, .retryWait(.gateFailed))
        XCTAssertEqual(failed.task.machine.attemptsUsed, 1)
        XCTAssertEqual(try String(contentsOfFile: gateClone.clonePath + "/gate.txt", encoding: .utf8), "gate\n")
        XCTAssertNotEqual(try gitStatus(gateClone.clonePath, ["show-ref", "--verify", "refs/kaban/wip/gate-run"]), 0)

        _ = try launch(f, "crash")
        let crashed = try f.store.prepareTaskClone(taskId: "crash", at: at, workspaceRoot: f.workspace)
        let head = try text(crashed.clonePath, ["rev-parse", "HEAD"])
        try "dirty\n".write(toFile: crashed.clonePath + "/note.txt", atomically: true, encoding: .utf8)
        _ = try until(f, contains: "process exit crash-run crash", runner: "/bin/sh", arguments: [crash])
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashed.clonePath + "/note.txt"))
        XCTAssertEqual(try text(crashed.clonePath, ["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try text(crashed.clonePath, ["show", "refs/kaban/wip/crash-run:note.txt"]).contains("dirty"))
        XCTAssertEqual(try task(f, "crash").machine.state, .retryWait(.crash))
        XCTAssertEqual(try task(f, "crash").machine.attemptsUsed, 1)
        XCTAssertEqual(try text(f.origin, ["rev-parse", "HEAD"]), before.head)
        XCTAssertEqual(try text(f.origin, ["rev-parse", "refs/heads/main"]), before.main)
        XCTAssertEqual(try text(f.origin, ["status", "--porcelain"]), "")
        XCTAssertNotEqual(try gitStatus(f.origin, ["show-ref", "--verify", "refs/kaban/wip/crash-run"]), 0)
    }

    func testWipRefusesTheUserCheckout() throws {
        let f = try fixture()
        let before = try mark(f.origin)
        _ = try launch(f, "origin")
        _ = try f.store.prepareTaskClone(taskId: "origin", at: at, workspaceRoot: f.workspace)
        _ = try apply(f, "origin", .runFailed(RunID(rawValue: "origin-run"), .crash), at: at)
        var record = try cloneRecord(f, "origin")
        record.clonePath = f.origin
        record.phase = "ready"
        try writeClone(f, record)
        XCTAssertThrowsError(try pass(f, at: at, runner: nil)) { XCTAssertEqual($0 as? TaskClone.Failure, .originProtected) }
        XCTAssertEqual(try text(f.origin, ["rev-parse", "HEAD"]), before.head)
        XCTAssertEqual(try text(f.origin, ["status", "--porcelain"]), "")
        XCTAssertNotEqual(try gitStatus(f.origin, ["show-ref", "--verify", "refs/kaban/wip/origin-run"]), 0)
    }

    func testDaemonReopenPrintsTheSameProcessResult() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the process launch") }
        let f = try fixture()
        let counter = f.root.appendingPathComponent("spawns").path
        FileManager.default.createFile(atPath: counter, contents: Data())
        let script = try script(f, "once.sh", "echo activity\nprintf x >> \"$1\"\nexit 0\n")
        let run = try launch(f, "task")
        let lines = try until(f, contains: "no_final_call", runner: "/bin/sh", arguments: [script, counter])
        XCTAssertEqual(lines, ["process group \(run.rawValue) started", "process exit \(run.rawValue) no_final_call"])
        XCTAssertEqual(try String(contentsOfFile: counter, encoding: .utf8), "x")
        _ = try f.store.execute(.init(command: .pauseAll), now: { at })
        let first = try runDaemon(executable, database: f.path, workspaces: f.workspace, runner: "/bin/sh", arguments: [script, counter])
        let second = try runDaemon(executable, database: f.path, workspaces: f.workspace, runner: "/bin/sh", arguments: [script, counter])
        XCTAssertEqual(first.exit, 0, first.stderr)
        XCTAssertEqual(second.exit, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        XCTAssertEqual(first.stderr, "process group \(run.rawValue) started\nprocess exit \(run.rawValue) no_final_call\n")
        XCTAssertEqual(try String(contentsOfFile: counter, encoding: .utf8), "x")
        if let dir = ProcessInfo.processInfo.environment["KABAN_PROCESS_EVIDENCE"] {
            let root = URL(fileURLWithPath: dir, isDirectory: true)
            try first.stderr.write(to: root.appendingPathComponent("be-08-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-08-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    func testRateLimitTextReleasesTheRunAndReopensIdentically() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the process launch") }
        let f = try fixture()
        let script = try script(f, "limit.sh", "echo 'Too many requests'\nexit 0\n")
        let run = try launch(f, "limited")
        let lines = try until(f, contains: "rate_limit", runner: "/bin/sh", arguments: [script])
        XCTAssertEqual(lines, ["process group \(run.rawValue) started", "process exit \(run.rawValue) rate_limit"])
        let failed = try task(f, "limited")
        XCTAssertEqual(failed.machine.state, .retryWait(.rateLimit))
        XCTAssertEqual(failed.machine.attemptsUsed, 0)
        XCTAssertEqual(failed.machine.runsSinceHuman, 0)
        let reopened = try KabanStore(path: f.path)
        guard case .rateLimited(let until, let step) = try reopened.getSnapshot().schedulerFlags.first else {
            return XCTFail("Missing cooldown after reopen")
        }
        XCTAssertEqual(step, 1)
        XCTAssertEqual(until, at.addingTimeInterval(15 * 60))
        _ = try f.store.execute(.init(command: .pauseAll), now: { at })
        let first = try runDaemon(executable, database: f.path, workspaces: f.workspace, runner: "/bin/sh", arguments: [script])
        let second = try runDaemon(executable, database: f.path, workspaces: f.workspace, runner: "/bin/sh", arguments: [script])
        XCTAssertEqual(first.exit, 0, first.stderr)
        XCTAssertEqual(second.exit, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        XCTAssertEqual(first.stderr, "process group \(run.rawValue) started\nprocess exit \(run.rawValue) rate_limit\n")
        XCTAssertEqual(try KabanStore(path: f.path).getSnapshot().schedulerFlags, try reopened.getSnapshot().schedulerFlags)
        if let dir = ProcessInfo.processInfo.environment["KABAN_PROCESS_EVIDENCE"] {
            let root = URL(fileURLWithPath: dir, isDirectory: true)
            try first.stderr.write(to: root.appendingPathComponent("be-15-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-15-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    /// A queued or retry-wait task is still eligible, so the next launch's tick would select it.
    /// Limit flags are durable now and would block that launch; this scenario is about charges, so drop them after the assertion.
    func release(_ f: Fixture, _ id: TaskID) throws {
        if try task(f, id).machine.state.status != .cancelled {
            _ = try apply(f, id, .cancel(keepBranch: false), at: at)
        }
        _ = try f.store.execute(.init(command: .resumeAfterRateLimit), now: { at })
        try f.store.database.write { db in
            var inputs = try KabanStore.schedulerInputs(db)
            inputs.flags.removeAll { flag in
                switch flag {
                case .rateLimited, .usageExhaustedUnknown, .poolUsageExhausted, .runnerUnavailable: true
                default: false
                }
            }
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try KabanStore.encode(inputs)])
        }
    }

    func effects(_ f: Fixture) throws -> [PendingEffect] {
        try f.store.database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM effect ORDER BY rowid").map { try KabanStore.decode(PendingEffect.self, $0) }
        }
    }

    struct Finished { var run: RunID; var receipt: DurableReceipt }
    func finish(_ f: Fixture, _ id: TaskID, _ command: DurableTaskCommand) throws -> Finished {
        try finish(f, id) { _ in command }
    }
    func finish(_ f: Fixture, _ id: TaskID, _ command: (RunID) -> DurableTaskCommand) throws -> Finished {
        let run = try launch(f, id)
        return Finished(run: run, receipt: try apply(f, id, command(run), at: at))
    }

    func summary(_ f: Fixture, _ id: TaskID, _ run: RunID) throws -> RunSummary {
        let data = try f.store.database.read { db in try XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM task_detail WHERE task_id = ?", arguments: [id.rawValue])) }
        return try XCTUnwrap(JSONDecoder().decode(StoredDetail.self, from: data).runs.first { $0.id == run })
    }

    func processRecord(_ f: Fixture, _ run: RunID) throws -> AgentProcessRecord {
        let data = try f.store.database.read { db in try XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM agent_process WHERE run_id = ?", arguments: [run.rawValue])) }
        return try JSONDecoder().decode(AgentProcessRecord.self, from: data)
    }

    func writeProcess(_ f: Fixture, _ record: AgentProcessRecord) throws {
        try f.store.database.write { db in
            try db.execute(sql: "UPDATE agent_process SET payload = ? WHERE run_id = ?", arguments: [try JSONEncoder().encode(record), record.runId])
        }
    }

    func cloneRecord(_ f: Fixture, _ id: TaskID) throws -> TaskCloneRecord {
        let data = try f.store.database.read { db in try XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM task_clone WHERE task_id = ?", arguments: [id.rawValue])) }
        return try JSONDecoder().decode(TaskCloneRecord.self, from: data)
    }

    func writeClone(_ f: Fixture, _ record: TaskCloneRecord) throws {
        try f.store.database.write { db in
            try db.execute(sql: "UPDATE task_clone SET payload = ? WHERE task_id = ?", arguments: [try JSONEncoder().encode(record), record.taskId.rawValue])
        }
    }

    func resetEffect(_ f: Fixture, _ id: String) throws {
        try f.store.database.write { db in
            try db.execute(sql: "UPDATE effect SET status = 'pending', lease_id = NULL, lease_owner = NULL, lease_until = NULL, external_fact = NULL, result = NULL, receipt = NULL WHERE id = ?", arguments: [id])
        }
    }

    func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    func waitForPid(_ path: String) throws -> Int32 {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("missing pid at \(path)")
        return 0
    }

    func waitForZombie(_ pid: Int32) throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if processState(pid).hasPrefix("Z") { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("process \(pid) state \(processState(pid))")
    }

    func waitUntilIdle(_ pid: Int32) throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline && isRunning(pid) { Thread.sleep(forTimeInterval: 0.02) }
    }

    func isRunning(_ pid: Int32) -> Bool {
        let state = processState(pid)
        return state.hasPrefix("S") || state.hasPrefix("R") || state.hasPrefix("U") || state.hasPrefix("D") || state.hasPrefix("I")
    }

    func processState(_ pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "state=", "-p", String(pid)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let body = try output(process)
        XCTAssertEqual(process.terminationStatus, 0, "\(args) \(body)")
        return body
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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    func output(_ process: Process) throws -> String {
        let data = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    struct OriginMark: Equatable { var head: String; var main: String }
    func mark(_ origin: String) throws -> OriginMark {
        OriginMark(head: try text(origin, ["rev-parse", "HEAD"]), main: try text(origin, ["rev-parse", "refs/heads/main"]))
    }

    struct DaemonOutput { var exit: Int32; var stderr: String }
    func runDaemon(_ binary: URL, database: String, workspaces: String, runner: String, arguments: [String]) throws -> DaemonOutput {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--process-pass", "--workspaces", workspaces, "--runner", runner] + arguments.flatMap { ["--runner-arg", $0] } + ["--stdio", "--database", database]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return DaemonOutput(exit: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
