import Foundation
import XCTest
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class RunLogTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let token = "KABAN_RUN_TOKEN=kaban-run-token-value"
    let secret = "sk-liveSecretValue99"

    func testOffsetsSurviveReconnectAndADeletedLogIsUnavailable() throws {
        let f = try fixture()
        let run = try prepare(f, "offsets")
        // Split one serialization: JSON object key order can differ between calls.
        let splitEvent = eventLine("two")
        let head = Data((eventLine("one") + "\n" + splitEvent.prefix(8)).utf8)
        try f.store.ingestAgentOutput(runId: run, taskId: "offsets", chunk: head, complete: false, directory: f.workspace)
        let early = try f.store.readLog(runId: run, fromOffset: 0, limit: 10)
        XCTAssertEqual(early.batch.events, [.message(role: "assistant", text: "one")])
        XCTAssertEqual(early.batch.nextOffset, 1)
        XCTAssertFalse(early.isComplete)
        let rest = Data(splitEvent.dropFirst(8).utf8) + Data(("\n" + eventLine("three") + "\n").utf8)
        try f.store.ingestAgentOutput(runId: run, taskId: "offsets", chunk: rest, complete: true, directory: f.workspace)

        let service = DaemonService(store: f.store)
        guard case .log(let first) = service.handle(.init(.readLog(runId: run, fromOffset: 0, limit: 2))).result else {
            return XCTFail("first page")
        }
        XCTAssertEqual(first.batch.fromOffset, 0)
        XCTAssertEqual(first.batch.nextOffset, 2)
        XCTAssertEqual(Int64(first.batch.events.count), first.batch.nextOffset - first.batch.fromOffset)
        XCTAssertEqual(first.batch.events, [.message(role: "assistant", text: "one"), .message(role: "assistant", text: "two")])
        let second = try f.store.readLog(runId: run, fromOffset: first.batch.nextOffset, limit: 2)
        XCTAssertEqual(second.batch.events, [.message(role: "assistant", text: "three")])
        XCTAssertEqual(second.batch.fromOffset, 2)
        XCTAssertEqual(second.batch.nextOffset, 3)
        XCTAssertEqual(second.endOffset, 3)
        XCTAssertTrue(second.isComplete)
        let again = try f.store.readLog(runId: run, fromOffset: 0, limit: 2)
        XCTAssertEqual(again.batch.events, first.batch.events)
        XCTAssertEqual(again.batch.nextOffset, first.batch.nextOffset)
        let caughtUp = try f.store.readLog(runId: run, fromOffset: second.endOffset, limit: 1)
        XCTAssertTrue(caughtUp.batch.events.isEmpty)
        XCTAssertEqual(caughtUp.batch.fromOffset, caughtUp.endOffset)

        let path = try XCTUnwrap(f.store.getTaskDetail("offsets").runs.first?.logPath)
        try FileManager.default.removeItem(atPath: path)
        let missing = service.handle(.init(.readLog(runId: run, fromOffset: 0, limit: 1)))
        guard case .error(let error) = missing.result else { return XCTFail("deleted log returned \(missing.result)") }
        XCTAssertEqual(error.code, CommandError.logUnavailableCode)
        XCTAssertFalse(error.message.isEmpty)
    }

    func testRetentionExpiresThePrefixWithoutRenumbering() throws {
        let f = try fixture()
        let run = try prepare(f, "trim")
        let count = RunLogRetention.maxEvents + 3
        var chunk = ""
        for index in 0..<count { chunk += eventLine("n\(index)") + "\n" }
        try f.store.ingestAgentOutput(runId: run, taskId: "trim", chunk: Data(chunk.utf8), complete: true, directory: f.workspace)
        do { _ = try f.store.readLog(runId: run, fromOffset: 0, limit: 1); XCTFail("trimmed prefix was still readable") }
        catch let error as CommandError {
            XCTAssertEqual(error.code, CommandError.logOffsetExpiredCode)
            XCTAssertEqual(error.params["availableFromOffset"], "3")
        }
        let page = try f.store.readLog(runId: run, fromOffset: 3, limit: 2)
        XCTAssertEqual(page.availableFromOffset, 3)
        XCTAssertEqual(page.batch.events, [.message(role: "assistant", text: "n3"), .message(role: "assistant", text: "n4")])
        XCTAssertEqual(page.batch.nextOffset, 5)
        let continued = try f.store.readLog(runId: run, fromOffset: page.batch.nextOffset, limit: 2)
        XCTAssertEqual(continued.batch.events, [.message(role: "assistant", text: "n5"), .message(role: "assistant", text: "n6")])
        XCTAssertEqual(continued.batch.fromOffset, page.batch.nextOffset)
        let same = try f.store.readLog(runId: run, fromOffset: 3, limit: 2)
        XCTAssertEqual(same.batch.events, page.batch.events)
        XCTAssertEqual(page.endOffset - page.availableFromOffset, Int64(RunLogRetention.maxEvents))
    }

    func testSecretsDoNotLandInArtifactsOrTheProcessLog() throws {
        let f = try fixture()
        let summaryRun = try prepare(f, "summary")
        _ = try f.store.apply(.completeStage(summaryRun, summary: "note \(token) \(secret)"), taskId: "summary", commandId: UUID(), at: at)
        let detail = try f.store.getTaskDetail("summary")
        let stored = detail.artifacts.map(\.text).joined(separator: "\n") + "\n" + detail.feed.map(\.text).joined(separator: "\n")
        XCTAssertFalse(stored.contains("kaban-run-token-value"))
        XCTAssertFalse(stored.contains(secret))
        XCTAssertTrue(stored.contains(SecretText.placeholder))
        XCTAssertEqual(detail.artifacts.first?.text.count, "note \(SecretText.placeholder) \(SecretText.placeholder)".count)

        let run = try prepare(f, "logged")
        let script = try script(f, "speak.sh", """
        printf '%s\\n' '\(eventLine("see \(token) \(secret)"))'
        printf '%s\\n' 'err \(token)' >&2
        exit 0
        """)
        let deadline = Date().addingTimeInterval(2)
        var page: LogPage?
        while Date() < deadline {
            _ = try f.store.runProcessPass(owner: "test", at: at, workspaceRoot: f.workspace, runner: "/bin/sh", runnerArguments: [script])
            page = try? f.store.readLog(runId: run, fromOffset: 0, limit: 10)
            if page?.batch.events.isEmpty == false { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let events = try XCTUnwrap(page).batch.events
        let rendered = events.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertFalse(rendered.contains("kaban-run-token-value"), rendered)
        XCTAssertFalse(rendered.contains(secret), rendered)
        XCTAssertEqual(events, [.message(role: "assistant", text: "see \(SecretText.placeholder) \(SecretText.placeholder)")])
        let logPath = try XCTUnwrap(f.store.getTaskDetail("logged").runs.first { $0.id == run }?.logPath)
        let logText = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertFalse(logText.contains("kaban-run-token-value"))
        XCTAssertFalse(logText.contains(secret))
        let stderrLog = URL(fileURLWithPath: logPath).deletingPathExtension().appendingPathExtension("err").path
        let stderrText = try String(contentsOfFile: stderrLog, encoding: .utf8)
        XCTAssertFalse(stderrText.contains("kaban-run-token-value"))
        let process = try XCTUnwrap(try f.store.agentProcesses().first { $0.runId == run })
        let stdout = try String(contentsOfFile: process.stdoutPath, encoding: .utf8)
        let processErr = try String(contentsOfFile: process.stderrPath, encoding: .utf8)
        XCTAssertFalse(stdout.contains("kaban-run-token-value"))
        XCTAssertFalse(stdout.contains(secret))
        XCTAssertFalse(processErr.contains("kaban-run-token-value"))
    }

    func testSnapshotAndDetailTooLargeFailExplicitly() throws {
        let f = try fixture()
        let run = try prepare(f, "medium")
        let body = String(repeating: "m", count: 20_000)
        _ = try f.store.apply(.completeStage(run, summary: body), taskId: "medium", commandId: UUID(), at: at)
        XCTAssertEqual(try f.store.getTaskDetail("medium").artifacts.map(\.text).joined(), body)

        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let created = try f.store.execute(.init(command: .createTask(projectId: project, title: "wide", body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), now: { at }, makeTaskID: { "wide" })
        XCTAssertEqual(created.result, .taskCreated("wide"))
        let wide = String(repeating: "w", count: 20_000)
        XCTAssertEqual(try f.store.execute(.init(command: .editTask(taskId: "wide", title: wide, body: nil)), now: { at }).result, .ok)
        XCTAssertEqual(try f.store.getSnapshot().tasks.first { $0.id == "wide" }?.title.count, 20_000)
        XCTAssertEqual(try f.store.getTaskDetail("wide").task.title.count, 20_000)

        let huge = String(repeating: "h", count: DaemonWire.maxMessageBytes)
        XCTAssertEqual(try f.store.execute(.init(command: .editTask(taskId: "wide", title: huge, body: nil)), now: { at }).result, .ok)
        XCTAssertEqual(try f.store.snapshot().tasks.first { $0.card.id == "wide" }?.card.title.count, DaemonWire.maxMessageBytes)
        let service = DaemonService(store: f.store)
        let encoded = service.handle(data: try DaemonWire.encode(DaemonRequest(.snapshot)))
        guard case .error(let snapshotError) = try DaemonWire.decode(DaemonResponse.self, from: encoded).result else {
            return XCTFail("oversized snapshot was returned")
        }
        XCTAssertEqual(snapshotError.code, CommandError.snapshotTooLargeCode)
        XCTAssertEqual(snapshotError.params["limit"], String(DaemonWire.maxMessageBytes))
        XCTAssertGreaterThan(Int(snapshotError.params["bytes"] ?? "0") ?? 0, DaemonWire.maxMessageBytes)
        guard case .error(let detailError) = try f.store.execute(.init(command: .getTaskDetail(taskId: "wide"))).result else {
            return XCTFail("oversized detail was returned")
        }
        XCTAssertEqual(detailError.code, CommandError.detailTooLargeCode)
        guard case .runs = try f.store.execute(.init(command: .getRunHistory(taskId: "wide"))).result else {
            return XCTFail("run history was not recoverable")
        }
        XCTAssertEqual(try f.store.getTaskDetail("medium").artifacts.map(\.text).joined(), body)
        try f.store.discardJournal()
        let reopened = try KabanStore(path: f.path)
        XCTAssertEqual(try reopened.snapshot().tasks.first { $0.card.id == "wide" }?.card.title.count, DaemonWire.maxMessageBytes)
        XCTAssertThrowsError(try reopened.getSnapshot()) { error in
            guard case StoreError.rejected(let command) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(command.code, CommandError.snapshotTooLargeCode)
        }
        XCTAssertEqual(try reopened.getTaskDetail("medium").artifacts.map(\.text).joined(), body)
        XCTAssertEqual(try reopened.getTaskDetail("medium").runs.count, 1)
    }

    func testSlowReaderDoesNotStopTheScheduler() throws {
        let f = try fixture()
        let first = try prepare(f, "slow")
        var chunk = ""
        for index in 0..<4 { chunk += eventLine("e\(index)") + "\n" }
        try f.store.ingestAgentOutput(runId: first, taskId: "slow", chunk: Data(chunk.utf8), complete: false, directory: f.workspace)
        let opened = try f.store.readLog(runId: first, fromOffset: 0, limit: 1)
        XCTAssertEqual(opened.batch.events, [.message(role: "assistant", text: "e0")])
        try f.store.ingestAgentOutput(runId: first, taskId: "slow", chunk: Data((eventLine("e4") + "\n").utf8), complete: false, directory: f.workspace)
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let created = try f.store.execute(.init(command: .createTask(projectId: project, title: "next", body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), now: { at }, makeTaskID: { "next" })
        XCTAssertEqual(created.result, .taskCreated("next"))
        let admitted = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: "next-admit"), at: at)
        XCTAssertEqual(admitted.transitions.last?.task.card.id, "next")
        XCTAssertEqual(admitted.transitions.last?.task.machine.stageId.rawValue, "dev")
        let started = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: "next-run"), at: at)
        XCTAssertEqual(started.transitions.last?.task.machine.state, .running)
        let reread = try f.store.readLog(runId: first, fromOffset: 0, limit: 1)
        XCTAssertEqual(reread.batch.events, opened.batch.events)
        let rest = try f.store.readLog(runId: first, fromOffset: opened.batch.nextOffset, limit: 10)
        XCTAssertEqual(rest.batch.events, [
            .message(role: "assistant", text: "e1"),
            .message(role: "assistant", text: "e2"),
            .message(role: "assistant", text: "e3"),
            .message(role: "assistant", text: "e4"),
        ])
        XCTAssertEqual(rest.batch.fromOffset, opened.batch.nextOffset)
    }

    func testRunsArtifactsAndAnswersSurviveJournalTrim() throws {
        let f = try fixture()
        let run = try prepare(f, "ask")
        try f.store.ingestAgentOutput(runId: run, taskId: "ask", chunk: Data((eventLine("working") + "\n").utf8), complete: true, directory: f.workspace)
        _ = try f.store.apply(.requestHuman(run, question: "where is the note"), taskId: "ask", commandId: UUID(), at: at)
        XCTAssertEqual(try f.store.execute(.init(command: .answerHuman(taskId: "ask", text: "on the desk", requestId: nil)), now: { at }).result, .ok)
        try f.store.discardJournal()
        let reopened = try KabanStore(path: f.path)
        let detail = try reopened.getTaskDetail("ask")
        XCTAssertEqual(detail.runs.count, 1)
        XCTAssertEqual(detail.runs.first?.logPath?.isEmpty, false)
        XCTAssertEqual(detail.humanRequests.map(\.question), ["where is the note"])
        XCTAssertTrue(detail.feed.contains { $0.kind == "answer" && $0.text == "on the desk" })
        let page = try reopened.readLog(runId: run, fromOffset: 0, limit: 10)
        XCTAssertEqual(page.batch.events, [.message(role: "assistant", text: "working")])
        XCTAssertTrue(page.isComplete)
    }

    func testDaemonLaunchesTwice() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the log launch") }
        let f = try fixture()
        _ = try prepare(f, "page")
        XCTAssertEqual(try f.store.execute(.init(command: .pauseAll), now: { at }).result, .ok)
        let run = RunID(rawValue: "page-log")
        try f.store.ingestAgentOutput(runId: run, taskId: "page", chunk: Data((eventLine("ready") + "\n").utf8), complete: true, directory: f.workspace)
        let page = try f.store.readLog(runId: run, fromOffset: 0, limit: 1)
        let first = try runDaemon(executable, database: f.path)
        let second = try runDaemon(executable, database: f.path)
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        XCTAssertTrue(first.stderr.contains("log \(run.rawValue) \(page.availableFromOffset) \(page.batch.nextOffset) \(page.endOffset) complete"))
        if let root = ProcessInfo.processInfo.environment["KABAN_PROCESS_EVIDENCE"].map(URL.init(fileURLWithPath:)) {
            try first.stderr.write(to: root.appendingPathComponent("be-16-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-16-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    private func eventLine(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "assistant", "text": text])
        return String(decoding: data, as: UTF8.self)
    }

    private struct Fixture { let root: URL; let workspace: String; let path: String; var store: KabanStore }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-log-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        try pipeline.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try "skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["config", "user.name", "Log Test"])
        try git(repo, ["config", "user.email", "log@example.test"])
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "Pipeline"])
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result, .ok)
        _ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        return Fixture(root: root, workspace: root.appendingPathComponent("workspaces").path, path: path, store: store)
    }

    private var pipeline: String {
        """
        version: 1
        board: {max_waiting_human: 4, max_runs_per_task: 12}
        stages:
          - {id: backlog, kind: queue, on_success: dev}
          - id: dev
            kind: agent
            wip: 4
            agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review
          - {id: review, kind: human, wip: 4, on_success: merge}
          - {id: merge, kind: merge, wip: 1, on_success: done}
          - {id: done, kind: terminal}

        """
    }

    @discardableResult
    private func prepare(_ f: Fixture, _ id: TaskID) throws -> RunID {
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let reply = try f.store.execute(.init(command: .createTask(projectId: project, title: id.rawValue, body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), now: { at }, makeTaskID: { id })
        XCTAssertEqual(reply.result, .taskCreated(id))
        _ = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-admit"), at: at)
        let started = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-run"), at: at)
        XCTAssertEqual(started.transitions.last?.task.machine.state, .running)
        return try XCTUnwrap(started.transitions.last?.task.machine.currentRunId)
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(args)")
    }

    private struct DaemonOutput { var status: Int32; var stderr: String }
    private func runDaemon(_ binary: URL, database: String) throws -> DaemonOutput {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--log-pass", "--stdio", "--database", database]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return DaemonOutput(status: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
