import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore
#if canImport(Darwin)
import Darwin
#endif

final class StageGateTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testGreenExitDoesNotReplaceTheFinalCall() throws {
        let f = try fixture(pipeline(devGates: "/usr/bin/true", maxRuns: 1))
        let run = try launch(f, "loud")
        let lines = try untilExit(f, run)
        XCTAssertTrue(lines.contains { $0.contains("process exit \(run.rawValue) no_final_call") })
        let task = try task(f, "loud")
        XCTAssertEqual(task.machine.state, .waitingHuman(.runLimit))
        XCTAssertNotEqual(task.machine.state.status, .gating)
        XCTAssertNotEqual(task.machine.state.status, .done)
        let detail = try f.store.getTaskDetail("loud")
        XCTAssertFalse(detail.artifacts.contains { $0.kind == "summary" })
        XCTAssertFalse(try f.store.pendingEffectItems().contains { if case .runGates = $0.effect { return $0.taskId == "loud" }; return false })
    }

    func testRedStageGateRepeatsTheSameStageAndClone() throws {
        let f = try fixture(pipeline(devGates: "printf red-gate && exit 1"))
        _ = try launch(f, "dev")
        let clone = try prepare(f, "dev")
        let before = clone.clonePath
        _ = try apply(f, "dev", .completeStage(try runId(f, "dev"), summary: "not yet"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        let failed = try task(f, "dev")
        XCTAssertEqual(failed.machine.state, .retryWait(.gateFailed))
        XCTAssertEqual(failed.machine.stageId.rawValue, "dev")
        XCTAssertEqual(failed.machine.attemptsUsed, 1)
        XCTAssertEqual(try f.store.getTaskDetail("dev").clonePath, before)
        let detail = try f.store.getTaskDetail("dev")
        XCTAssertTrue(detail.artifacts.contains { $0.kind == "gate_output" && $0.text.contains("red-gate") })
        // The stage backoff is 30s; the scheduler keeps the retry blocked until that instant.
        _ = try apply(f, "dev", .start(RunID(rawValue: "dev-again")), at: at.addingTimeInterval(31))
        let prompt = try startPrompt(f, "dev")
        XCTAssertTrue(prompt.contains { if case .gateOutput(let text) = $0 { return text.contains("red-gate") }; return false })
        let request = try startRequest(f, "dev")
        XCTAssertTrue(request.continueInClone)
        XCTAssertEqual(try f.store.getTaskDetail("dev").clonePath, before)
    }

    func testRedStandaloneGateReturnsToTheCodingStage() throws {
        let f = try fixture(pipeline(devGates: "/usr/bin/true", lint: "printf lint-failed && exit 1"))
        _ = try launch(f, "lint")
        let clone = try prepare(f, "lint")
        _ = try apply(f, "lint", .completeStage(try runId(f, "lint"), summary: "dev"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(try task(f, "lint").machine.stageId.rawValue, "lint")
        _ = try apply(f, "lint", .start(RunID(rawValue: "lint-gate")))
        _ = try f.store.runStagePass(owner: "test", at: at)
        let returned = try task(f, "lint")
        XCTAssertEqual(returned.machine.stageId.rawValue, "dev")
        XCTAssertEqual(returned.machine.state.status, .queued)
        XCTAssertEqual(returned.machine.attemptsUsed, 0)
        XCTAssertEqual(try f.store.getTaskDetail("lint").clonePath, clone.clonePath)
        _ = try apply(f, "lint", .start(RunID(rawValue: "dev-again")))
        let prompt = try startPrompt(f, "lint")
        XCTAssertTrue(prompt.contains { if case .gateOutput(let text) = $0 { return text.contains("lint-failed") }; return false })
    }

    func testReturnCarriesIssuesAndResetsAttempts() throws {
        let f = try fixture(pipeline(devGates: "if [ -f fail ]; then printf red-gate && exit 1; else exit 0; fi", returns: 3, totalBounces: 1))
        _ = try launch(f, "back")
        let clone = try prepare(f, "back")
        try "x".write(to: URL(fileURLWithPath: clone.clonePath).appendingPathComponent("fail"), atomically: true, encoding: .utf8)
        _ = try apply(f, "back", .completeStage(try runId(f, "back"), summary: "first"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(try task(f, "back").machine.attemptsUsed, 1)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: clone.clonePath).appendingPathComponent("fail"))
        _ = try apply(f, "back", .start(RunID(rawValue: "back-2")), at: at.addingTimeInterval(31))
        _ = try apply(f, "back", .completeStage(try runId(f, "back"), summary: "second"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(try task(f, "back").machine.stageId.rawValue, "test")
        XCTAssertEqual(try task(f, "back").machine.attemptsUsed, 0)
        _ = try apply(f, "back", .start(RunID(rawValue: "test-1")))
        _ = try apply(f, "back", .returnToStage(try runId(f, "back"), target: "dev", issues: ["button overlaps the label"]))
        let returned = try task(f, "back")
        XCTAssertEqual(returned.machine.stageId.rawValue, "dev")
        XCTAssertEqual(returned.machine.attemptsUsed, 0)
        let detail = try f.store.getTaskDetail("back")
        XCTAssertTrue(detail.artifacts.contains { $0.kind == "issue" && $0.text == "button overlaps the label" })
        _ = try apply(f, "back", .start(RunID(rawValue: "dev-3")))
        let prompt = try startPrompt(f, "back")
        XCTAssertTrue(prompt.contains { if case .returnIssues(_, let issues) = $0 { return issues == ["button overlaps the label"] }; return false })
        _ = try f.store.runStagePass(owner: "test", at: at)
        _ = try apply(f, "back", .completeStage(try runId(f, "back"), summary: "third"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        _ = try apply(f, "back", .start(RunID(rawValue: "test-2")))
        _ = try apply(f, "back", .returnToStage(try runId(f, "back"), target: "dev", issues: ["again"]))
        XCTAssertEqual(try task(f, "back").machine.state, .waitingHuman(.bounceLimit))
    }

    func testReplayDoesNotCommitOrHookTwiceAndThePipelineReachesReview() throws {
        let f = try fixture(pipeline(devGates: "/usr/bin/true", hooks: true))
        _ = try launch(f, "full")
        let clone = try prepare(f, "full")
        let root = URL(fileURLWithPath: clone.clonePath)
        try "note".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let planted = root.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nprintf planted > planted\n".write(to: planted, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: planted.path)
        let before = try count(root)
        _ = try apply(f, "full", .completeStage(try runId(f, "full"), summary: "Dev done"))
        let first = try f.store.runStagePass(owner: "test", at: at)
        let second = try f.store.runStagePass(owner: "test", at: at)
        _ = try f.store.recover(passId: UUID(), at: at)
        let third = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("hook-log"), encoding: .utf8), "enterexit")
        XCTAssertEqual(try count(root), before + 1)
        XCTAssertTrue(try subjects(root).contains { $0.hasPrefix("kaban: dev ") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("planted").path))
        let detail = try f.store.getTaskDetail("full")
        XCTAssertTrue(detail.artifacts.contains { $0.kind == "diffstat" && $0.text.contains("note.txt") })
        XCTAssertTrue(detail.artifacts.contains { $0.kind == "summary" && $0.text == "Dev done" })
        XCTAssertEqual(try task(f, "full").machine.stageId.rawValue, "test")
        try "checked".write(to: root.appendingPathComponent("test-note.txt"), atomically: true, encoding: .utf8)
        _ = try apply(f, "full", .start(RunID(rawValue: "test-run")))
        _ = try apply(f, "full", .completeStage(try runId(f, "full"), summary: "Test done"))
        let testPass = try f.store.runStagePass(owner: "test", at: at)
        let testReplay = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(testPass, testReplay)
        XCTAssertEqual(try count(root), before + 2)
        XCTAssertTrue(try subjects(root).contains { $0.hasPrefix("kaban: test ") })
        _ = try apply(f, "full", .start(RunID(rawValue: "review-run")))
        let review = try task(f, "full")
        XCTAssertEqual(review.machine.stageId.rawValue, "review")
        XCTAssertEqual(review.machine.state, .waitingHuman(.review))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("hook-log"), encoding: .utf8), "enterexit")
        XCTAssertEqual(try count(root), before + 2)
    }

    func testStrictPresetCommitsTheSummaryOnce() throws {
        let f = try fixture(pipeline(devGates: "/usr/bin/true", preset: "strict"))
        _ = try launch(f, "strict")
        let clone = try prepare(f, "strict")
        try "form".write(to: URL(fileURLWithPath: clone.clonePath).appendingPathComponent("form.txt"), atomically: true, encoding: .utf8)
        _ = try apply(f, "strict", .completeStage(try runId(f, "strict"), summary: "Ship the form"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        _ = try f.store.runStagePass(owner: "test", at: at)
        let titles = try subjects(URL(fileURLWithPath: clone.clonePath))
        XCTAssertEqual(titles.filter { $0 == "Ship the form" }.count, 1)
    }

    func testReadOnlyChangesRollBackAndTheSecondStrikeWaits() throws {
        let f = try fixture(pipeline(devGates: "/usr/bin/true", readOnly: true))
        _ = try launch(f, "ro")
        let clone = try prepare(f, "ro")
        _ = try apply(f, "ro", .completeStage(try runId(f, "ro"), summary: "dev"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(try task(f, "ro").machine.stageId.rawValue, "inspect")
        _ = try apply(f, "ro", .start(RunID(rawValue: "inspect-1")))
        let file = URL(fileURLWithPath: clone.clonePath).appendingPathComponent("dirty.txt")
        try "dirty".write(to: file, atomically: true, encoding: .utf8)
        _ = try apply(f, "ro", .completeStage(try runId(f, "ro"), summary: "inspect"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        let once = try task(f, "ro")
        XCTAssertEqual(once.machine.state, .retryWait(.readonlyViolation))
        XCTAssertEqual(once.machine.stageId.rawValue, "inspect")
        XCTAssertEqual(once.machine.attemptsUsed, 1)
        XCTAssertEqual(once.machine.invalidResultStrikes, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        _ = try apply(f, "ro", .start(RunID(rawValue: "inspect-2")), at: at.addingTimeInterval(31))
        try "dirty".write(to: file, atomically: true, encoding: .utf8)
        _ = try apply(f, "ro", .completeStage(try runId(f, "ro"), summary: "again"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        let twice = try task(f, "ro")
        XCTAssertEqual(twice.machine.state, .waitingHuman(.invalidResult))
        XCTAssertEqual(twice.machine.invalidResultStrikes, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDaemonPrintsOneStagePassTwice() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the stage launch") }
        let f = try fixture(pipeline(devGates: "/usr/bin/true", hooks: true))
        _ = try launch(f, "once")
        let clone = try prepare(f, "once")
        try "note".write(to: URL(fileURLWithPath: clone.clonePath).appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        _ = try apply(f, "once", .completeStage(try runId(f, "once"), summary: "Dev done"))
        let first = try runDaemon(executable, database: f.path)
        let second = try runDaemon(executable, database: f.path)
        XCTAssertEqual(first.exit, 0, first.stderr)
        XCTAssertEqual(second.exit, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        XCTAssertTrue(first.stderr.contains("stage once gate dev passed"))
        XCTAssertTrue(first.stderr.contains("stage once commit dev "))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: clone.clonePath).appendingPathComponent("hook-log"), encoding: .utf8), "enterexit")
        XCTAssertEqual(try task(f, "once").machine.stageId.rawValue, "test")
        if let root = ProcessInfo.processInfo.environment["KABAN_PROCESS_EVIDENCE"].map(URL.init(fileURLWithPath:)) {
            try first.stderr.write(to: root.appendingPathComponent("be-11-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-11-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    private struct Fixture { let root: URL; let workspace: String; let path: String; var store: KabanStore; let origin: String }

    func testStartupRecoveryRepeatsInterruptedGatesAndReconcilesStageCommit() throws {
        let f = try fixture(pipeline(devGates: "/usr/bin/true"))
        let run = try launch(f, "gate-crash")
        let clone = try prepare(f, "gate-crash")
        try "draft".write(toFile: clone.clonePath + "/draft.txt", atomically: true, encoding: .utf8)
        _ = try apply(f, "gate-crash", .completeStage(run, summary: "done"))
        let old = try XCTUnwrap(f.store.pendingEffectItems().first { if case .runGates = $0.effect { return true }; return false })
        _ = try f.store.claimEffect(id: old.id, owner: "dead", at: at)
        try f.store.database.write { db in
            try db.execute(sql: "INSERT INTO stage_work(id, task_id, entry, stage_id, kind, command, status, output, code, effect_id) VALUES ('dead-gate', 'gate-crash', 1, 'dev', 'gate', '/usr/bin/true', 'running', '', 0, ?)", arguments: [old.id])
        }
        let reopened = try KabanStore(path: f.path)
        _ = try reopened.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        let after = try XCTUnwrap(reopened.snapshot().tasks.first { $0.card.id == "gate-crash" })
        XCTAssertEqual(after.machine.attemptsUsed, 0)
        XCTAssertNotEqual(after.machine.state.status, .retryWait)
        XCTAssertEqual(try reopened.getTaskDetail("gate-crash").runs.first?.status, .succeeded)
        let commitCount = try count(URL(fileURLWithPath: clone.clonePath))
        let seq = try reopened.snapshot().seq
        _ = try reopened.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try reopened.snapshot().seq, seq)
        XCTAssertEqual(try count(URL(fileURLWithPath: clone.clonePath)), commitCount)
    }

    func testStartupFindsStageCommitBeforeDatabaseReceipt() throws {
        let f = try fixture(pipeline(devGates: "/usr/bin/true"))
        let run = try launch(f, "commit-crash")
        let clone = try prepare(f, "commit-crash")
        try "draft".write(toFile: clone.clonePath + "/draft.txt", atomically: true, encoding: .utf8)
        _ = try apply(f, "commit-crash", .completeStage(run, summary: "commit once"))
        _ = try apply(f, "commit-crash", .gatesPassed)
        _ = try apply(f, "commit-crash", .resultClean)
        let row = try f.store.database.read { db in try XCTUnwrap(Row.fetchOne(db, sql: "SELECT id, command FROM stage_work WHERE kind = 'commit'")) }
        let identity = try f.store.getSnapshot().projects.first?.identity
        _ = try TaskClone.commitMarked(clone: clone.clonePath, message: row["command"], marker: TaskClone.effectMarkerPrefix + (row["id"] as String), identity: identity)
        let commitCount = try count(URL(fileURLWithPath: clone.clonePath))
        let reopened = try KabanStore(path: f.path)
        _ = try reopened.recoverProduction(passId: UUID(), at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try count(URL(fileURLWithPath: clone.clonePath)), commitCount)
        XCTAssertEqual(try reopened.getTaskDetail("commit-crash").artifacts.filter { $0.kind == "summary" }.count, 1)
    }

    private func pipeline(devGates: String, lint: String? = nil, hooks: Bool = false, readOnly: Bool = false, preset: String? = nil, returns: Int = 3, totalBounces: Int = 5, maxRuns: Int = 12) -> String {
        let hook = hooks ? "\n    hooks: {on_enter: \"printf enter >> hook-log\", on_exit: \"printf exit >> hook-log\"}" : ""
        let git = preset.map { "git: {preset: \($0)}\n" } ?? ""
        let afterDev = lint == nil ? (readOnly ? "inspect" : "test") : "lint"
        let lintStage = lint.map { command in """
          - id: lint
            kind: gate
            wip: 1
            gates: ["\(command)"]
            on_success: test
        """ } ?? ""
        let inspect = readOnly ? """
          - id: inspect
            kind: agent
            wip: 2
            agent: {model: explicit, skill: .kaban/dev.md, permissions: read-only}
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review
        """ : """
          - id: test
            kind: agent
            wip: 2
            agent: {model: explicit, skill: .kaban/dev.md}
            returns_to: [{stage: dev, limit: \(returns)}]
            gates: ["/usr/bin/true"]
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review
        """
        return """
        version: 1
        board: {max_waiting_human: 4, bounce_limit_total: \(totalBounces), max_runs_per_task: \(maxRuns)}
        \(git)stages:
          - {id: backlog, kind: queue, on_success: dev}
          - id: dev
            kind: agent
            wip: 2
            agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
            gates: ["\(devGates)"]\(hook)
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: \(afterDev)
        \(lintStage)
        \(inspect)
          - {id: review, kind: human, wip: 2, on_success: merge}
          - {id: merge, kind: merge, wip: 1, on_success: done}
          - {id: done, kind: terminal}
        """
    }

    private func fixture(_ yaml: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-stage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        try yaml.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try "skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["config", "user.name", "Stage Test"])
        try git(repo, ["config", "user.email", "stage@example.test"])
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "Pipeline"])
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result, .ok)
        _ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        return Fixture(root: root, workspace: root.appendingPathComponent("workspaces").path, path: path, store: store, origin: repo.path)
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

    private func startRequest(_ f: Fixture, _ id: TaskID) throws -> AgentRunRequest {
        let request = try f.store.pendingEffectItems().compactMap { item -> AgentRunRequest? in
            guard item.taskId == id, case .startAgentRun(let request) = item.effect else { return nil }
            return request
        }.first
        return try XCTUnwrap(request)
    }

    private func startPrompt(_ f: Fixture, _ id: TaskID) throws -> [PromptAddition] {
        try startRequest(f, id).prompt
    }

    private func untilExit(_ f: Fixture, _ run: RunID) throws -> [String] {
        let script = try script(f, "until.sh", "echo activity\nexit 0\n")
        let deadline = Date().addingTimeInterval(2)
        var lines: [String] = []
        while Date() < deadline {
            lines = try f.store.runProcessPass(owner: "test", at: at, workspaceRoot: f.workspace, runner: "/bin/sh", runnerArguments: [script])
            if lines.contains(where: { $0.contains("process exit \(run.rawValue)") }) { return lines }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return lines
    }

    private func script(_ f: Fixture, _ name: String, _ body: String) throws -> String {
        let url = f.root.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.path
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

    private func subjects(_ repo: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "log", "--format=%s"]
        process.environment = DaemonGit.processEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func count(_ repo: URL) throws -> Int {
        try subjects(repo).count
    }

    private struct DaemonOutput { var exit: Int32; var stderr: String }
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
        return DaemonOutput(exit: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
