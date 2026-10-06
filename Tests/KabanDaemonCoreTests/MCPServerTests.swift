import XCTest
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class MCPServerTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    private let body = "Task\n\n## Критерии приёмки\n- [ ] Ready\n"

    func testForeignRevokedAndStaleTokensDoNotChangeTheTask() throws {
        let fixture = try store()
        try running("a", fixture.store)
        try running("b", fixture.store)
        let server = try MCPBoardServer(store: fixture.store, now: { self.at })
        defer { server.stop() }
        XCTAssertEqual(server.host, "127.0.0.1")
        let tokenA = try fixture.store.issueRunToken(taskId: "a", at: at)
        let beforeA = try payload(fixture.store, "a")
        let beforeB = try payload(fixture.store, "b")
        let foreign = try post(server, token: "foreign-token", method: "tools/call", params: ["name": "complete_stage", "arguments": ["summary": "no"]])
        XCTAssertEqual(foreign.status, 401)
        let swapped = try post(server, token: tokenA, method: "tools/call", params: ["name": "report_progress", "arguments": ["taskId": "b", "text": "stolen"]])
        XCTAssertEqual(swapped.status, 200)
        XCTAssertNotNil(swapped.json["error"])
        XCTAssertEqual(try payload(fixture.store, "a"), beforeA)
        XCTAssertEqual(try payload(fixture.store, "b"), beforeB)

        _ = try fixture.store.apply(.runFailed("run-a", .crash), taskId: "a", commandId: UUID(), at: at)
        try running("a", fixture.store, run: "run-a2", at: at.addingTimeInterval(30))
        let during = try payload(fixture.store, "a")
        let stale = try post(server, token: tokenA, method: "tools/call", params: ["name": "complete_stage", "arguments": ["summary": "late"]])
        XCTAssertEqual(stale.status, 401)
        XCTAssertEqual(try payload(fixture.store, "a"), during)
        XCTAssertEqual(try task("a", fixture.store).machine.currentRunId, RunID(rawValue: "run-a2"))
        XCTAssertEqual(try task("a", fixture.store).machine.state, .running)

        let live = try fixture.store.issueRunToken(taskId: "a", at: at.addingTimeInterval(30))
        let asked = try post(server, token: live, method: "tools/call", params: ["name": "request_human", "arguments": ["question": "which file?"]])
        XCTAssertEqual(asked.status, 200)
        let afterAsk = try payload(fixture.store, "a")
        let revoked = try post(server, token: live, method: "tools/call", params: ["name": "report_progress", "arguments": ["text": "still here"]])
        XCTAssertEqual(revoked.status, 401)
        XCTAssertEqual(try payload(fixture.store, "a"), afterAsk)
        XCTAssertEqual(try fixture.store.getTaskDetail("a").feed.filter { $0.kind == "progress" }.count, 0)
    }

    func testDuplicateCompletionDoesNotTransitionTwice() throws {
        let fixture = try store()
        try running("a", fixture.store)
        let server = try MCPBoardServer(store: fixture.store, now: { self.at })
        defer { server.stop() }
        let token = try fixture.store.issueRunToken(taskId: "a", at: at)
        let before = try gatingCount(fixture.store)
        let first = try post(server, token: token, method: "tools/call", params: [
            "name": "complete_stage",
            "arguments": ["summary": "stage ready", "artifacts": [["kind": "note", "text": "diffstat"]]],
        ])
        XCTAssertEqual(first.status, 200)
        XCTAssertNil(first.json["error"])
        let finished = try task("a", fixture.store)
        XCTAssertEqual(finished.machine.state, .gating)
        XCTAssertEqual(finished.machine.stageId.rawValue, "agent")
        XCTAssertNotEqual(finished.machine.state.status, .done)
        XCTAssertTrue(try fixture.store.pendingEffects().flatMap(\.effects).contains { if case .runGates = $0 { true } else { false } })
        let second = try post(server, token: token, method: "tools/call", params: ["name": "complete_stage", "arguments": ["summary": "again"]])
        XCTAssertEqual(second.status, 200)
        XCTAssertNil(second.json["error"])
        XCTAssertEqual(try gatingCount(fixture.store), before + 1)
        XCTAssertEqual(try task("a", fixture.store).machine.state, .gating)
        let detail = try fixture.store.getTaskDetail("a")
        XCTAssertEqual(detail.artifacts.first { $0.kind == "summary" }?.text, "stage ready")
        XCTAssertEqual(detail.artifacts.first { $0.kind == "note" }?.text, "diffstat")
        let listed = try post(server, token: token, method: "tools/list", params: [:])
        let names = ((listed.json["result"] as? [String: Any])?["tools"] as? [Any])?.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["get_task_context", "report_progress", "complete_stage", "return_to_stage", "request_human"])
    }

    func testIllegalReturnFreesTheSlotOnlyForAHumanQuestion() throws {
        let fixture = try store()
        _ = try fixture.store.setSettings(GlobalSettings(maxConcurrentRuns: 1, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at)
        try running("a", fixture.store)
        try queuedAgent("b", fixture.store)
        let server = try MCPBoardServer(store: fixture.store, now: { self.at })
        defer { server.stop() }
        let token = try fixture.store.issueRunToken(taskId: "a", at: at)
        let blocked = try task("b", fixture.store)
        XCTAssertFalse(try fixture.store.database.read { try KabanStore.canStart(blocked, at: self.at, db: $0) })
        let before = try gatingCount(fixture.store)
        let illegal = try post(server, token: token, method: "tools/call", params: ["name": "return_to_stage", "arguments": ["target": "done", "issues": ["not this stage"]]])
        XCTAssertEqual(illegal.status, 200)
        let message = ((illegal.json["error"] as? [String: Any])?["message"] as? String) ?? ""
        XCTAssertTrue(message.contains("return_to_stage"), message)
        XCTAssertEqual(try task("a", fixture.store).machine.state, .running)
        XCTAssertEqual(try gatingCount(fixture.store), before)
        XCTAssertEqual(try fixture.store.getTaskDetail("a").artifacts.filter { $0.kind == "issue" }.count, 0)
        let progress = try post(server, token: token, method: "tools/call", params: ["name": "report_progress", "arguments": ["text": "reading the diff"]])
        XCTAssertEqual(progress.status, 200)
        XCTAssertEqual(try task("a", fixture.store).machine.state, .running)
        XCTAssertEqual(try fixture.store.getTaskDetail("a").feed.filter { $0.kind == "progress" }.map(\.text), ["reading the diff"])
        let huge = String(repeating: "x", count: 4_097)
        let bounded = try post(server, token: token, method: "tools/call", params: ["name": "report_progress", "arguments": ["text": huge]])
        XCTAssertEqual(bounded.status, 200)
        XCTAssertNotNil(bounded.json["error"])
        XCTAssertEqual(try fixture.store.getTaskDetail("a").feed.filter { $0.kind == "progress" }.count, 1)

        let asked = try post(server, token: token, method: "tools/call", params: ["name": "request_human", "arguments": ["question": "which file?"]])
        XCTAssertEqual(asked.status, 200)
        let waiting = try task("a", fixture.store)
        XCTAssertEqual(waiting.machine.state, .waitingHuman(.question))
        XCTAssertNil(waiting.machine.currentRunId)
        XCTAssertEqual(waiting.machine.stageId.rawValue, "agent")
        XCTAssertEqual(try fixture.store.getTaskDetail("a").humanRequests.map(\.question), ["which file?"])
        let sibling = try task("b", fixture.store)
        XCTAssertTrue(try fixture.store.database.read { try KabanStore.canStart(sibling, at: self.at, db: $0) })
    }

    func testNoticesGoOnlyToTheAddressedTask() throws {
        let fixture = try store()
        try running("a", fixture.store)
        try running("b", fixture.store)
        let server = try MCPBoardServer(store: fixture.store, now: { self.at })
        defer { server.stop() }
        try fixture.store.queueGitGrantNotice(taskId: "a", argv: ["git", "rebase"], at: at)
        try fixture.store.queueGitGrantNotice(taskId: "b", argv: ["git", "stash"], at: at)
        let tokenA = try fixture.store.issueRunToken(taskId: "a", at: at)
        let tokenB = try fixture.store.issueRunToken(taskId: "b", at: at)
        let first = try post(server, token: tokenA, method: "tools/call", params: ["name": "get_task_context", "arguments": [:]])
        XCTAssertEqual(notices(first.json), ["git rebase разрешена один раз"])
        XCTAssertEqual(structured(first.json, "body") as? String, body)
        XCTAssertEqual(structured(first.json, "taskId") as? String, "a")
        XCTAssertNil(try fixture.store.getTaskDetail("b").gitGrants.first?.delivery)
        let second = try post(server, token: tokenA, method: "tools/call", params: ["name": "get_task_context", "arguments": [:]])
        XCTAssertEqual(notices(second.json), [])
        let other = try post(server, token: tokenB, method: "tools/call", params: ["name": "get_task_context", "arguments": [:]])
        XCTAssertEqual(notices(other.json), ["git stash разрешена один раз"])
        XCTAssertFalse(notices(first.json).joined().contains("stash"))
    }

    func testRunTokenIsOnlyInTheProcessEnvironment() throws {
        let fixture = try store()
        try running("a", fixture.store)
        let env = try fixture.store.environmentForAgentRun(taskId: "a", at: at)
        let token = try XCTUnwrap(env["KABAN_RUN_TOKEN"])
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: fixture.path + suffix)
            guard let data = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(data.range(of: Data(token.utf8)), suffix)
        }
        let directory = URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
        let script = directory.appendingPathComponent("env.sh")
        try "if [ -n \"$KABAN_RUN_TOKEN\" ]; then echo present; else echo missing; fi\n".write(to: script, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("out").path
        let error = directory.appendingPathComponent("err").path
        let handle = try ProcessGroup.spawn(executable: "/bin/sh", arguments: [script.path], workingDirectory: directory.path, environment: env, standardOutput: output, standardError: error)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && ProcessGroup.poll(handle.pid) == nil { Thread.sleep(forTimeInterval: 0.02) }
        let text = try String(contentsOfFile: output, encoding: .utf8)
        XCTAssertEqual(text, "present\n")
        XCTAssertFalse(text.contains(token))
        XCTAssertFalse((try? String(contentsOfFile: error, encoding: .utf8))?.contains(token) == true)
    }

    func testDaemonPrintsOneMCPCompletionTwice() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the MCP launch") }
        let fixture = try store()
        try running("a", fixture.store)
        let first = try runDaemon(executable, database: fixture.path)
        let second = try runDaemon(executable, database: fixture.path)
        XCTAssertEqual(first.exit, 0, first.stderr)
        XCTAssertEqual(second.exit, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        XCTAssertEqual(first.stderr, "mcp complete run-a gating\n")
        let reopened = try KabanStore(path: fixture.path)
        XCTAssertEqual(try gatingCount(reopened), 1)
        if let dir = ProcessInfo.processInfo.environment["KABAN_PROCESS_EVIDENCE"] {
            let root = URL(fileURLWithPath: dir, isDirectory: true)
            try first.stderr.write(to: root.appendingPathComponent("be-09-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-09-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    private func store() throws -> (path: String, store: KabanStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let opened = try KabanStore(path: path)
        _ = try opened.registerProject(ProjectSummary(id: "p", name: "P", path: root.path, mascotSeed: "p"), pipeline: try ManagedEngineFixture.pipeline(), commandId: UUID(), at: at)
        _ = try opened.setSettings(GlobalSettings(maxConcurrentRuns: 4, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at)
        for id: TaskID in ["a", "b"] {
            _ = try opened.execute(.init(command: .createTask(projectId: "p", title: id.rawValue, body: body)), now: { at }, makeTaskID: { id })
        }
        return (path, opened)
    }

    private func queuedAgent(_ id: TaskID, _ store: KabanStore) throws {
        _ = try store.apply(.start(RunID(rawValue: "intake-\(id.rawValue)")), taskId: id, commandId: UUID(), at: at)
        XCTAssertEqual(try task(id, store).machine.state.status, .queued)
    }

    private func running(_ id: TaskID, _ store: KabanStore, run: RunID? = nil, at: Date? = nil) throws {
        let moment = at ?? self.at
        let current = try task(id, store)
        if current.machine.state.status == .queued && current.machine.stageId.rawValue == "queue" {
            _ = try store.apply(.start(RunID(rawValue: "intake-\(id.rawValue)")), taskId: id, commandId: UUID(), at: moment)
        }
        let runId = run ?? RunID(rawValue: "run-\(id.rawValue)")
        _ = try store.apply(.start(runId), taskId: id, commandId: UUID(), at: moment)
        XCTAssertEqual(try task(id, store).machine.state, .running)
    }

    private func task(_ id: TaskID, _ store: KabanStore) throws -> DurableTask {
        try store.database.read { try KabanStore.task(id, db: $0) }
    }

    private func payload(_ store: KabanStore, _ id: TaskID) throws -> Data {
        try store.database.read { db in try XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM task WHERE id = ?", arguments: [id.rawValue])) }
    }

    private func gatingCount(_ store: KabanStore) throws -> Int {
        try store.events().filter { event in
            if case .taskTransitioned(let transition) = event.event { return transition.to == .gating }
            return false
        }.count
    }

    private func notices(_ json: [String: Any]) -> [String] {
        ((json["result"] as? [String: Any])?["notices"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func structured(_ json: [String: Any], _ key: String) -> Any? {
        ((json["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?[key]
    }

    private func post(_ server: MCPBoardServer, token: String, method: String, params: [String: Any]) throws -> (status: Int, json: [String: Any]) {
        try server.roundTrip(token: token, method: method, params: params)
    }

    private struct DaemonOutput { var exit: Int32; var stderr: String }
    private func runDaemon(_ binary: URL, database: String) throws -> DaemonOutput {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--mcp-pass", "--stdio", "--database", database]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return DaemonOutput(exit: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
