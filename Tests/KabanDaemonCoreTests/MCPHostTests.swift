import Foundation
import XCTest
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class MCPHostTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testFakeAgentCompletesReturnsAndHitsTheLimitThroughTheHostServer() throws {
        let f = try fixture()
        try create(f, "flow")
        let review = try drive(f, "flow") { $0.machine.state == .waitingHuman(.bounceLimit) }
        XCTAssertEqual(review.machine.state, .waitingHuman(.bounceLimit))
        XCTAssertEqual(review.machine.stageId.rawValue, "test")
        XCTAssertEqual(try runCount(f), 4)
        XCTAssertEqual(try read(f, "complete-1.status"), "200")
        let completed = try read(f, "complete-1.json"), again = try read(f, "complete-again-1.json")
        let returned = try read(f, "return-2.json"), limited = try read(f, "return-4.json")
        XCTAssertTrue(completed.contains("\"state\":\"gating\""), completed)
        XCTAssertTrue(again.contains("complete_stage already recorded"), again)
        XCTAssertTrue(returned.contains("\"stageId\":\"dev\""), returned)
        XCTAssertEqual(try read(f, "return-again-2.status"), "200")
        XCTAssertEqual(try read(f, "return-again-4.status"), "200")
        XCTAssertTrue(limited.contains("\"state\":\"waiting_human\""), limited)
        let detail = try f.store.getTaskDetail("flow")
        XCTAssertEqual(detail.runs.count, 4)
        XCTAssertEqual(detail.artifacts.filter { $0.kind == "issue" }.map(\.text), ["again", "again"])
    }

    func testRunConfigHasOnlyTheBoardAndAllowlistedServersAndStaysOutOfTheBranch() throws {
        let f = try fixture()
        try create(f, "config")
        _ = try drive(f, "config") { $0.machine.stageId.rawValue == "test" && $0.machine.state == .running }
        let config = try JSONSerialization.jsonObject(with: Data(try read(f, "mcp-1.json").utf8)) as? [String: Any]
        let servers = try XCTUnwrap(config?["mcpServers"] as? [String: Any])
        XCTAssertEqual(servers.keys.sorted(), ["github", "kaban"])
        let board = try XCTUnwrap(servers["kaban"] as? [String: Any])
        XCTAssertEqual(board["url"] as? String, f.store.mcpEndpoint?.boardURL)
        XCTAssertEqual((board["headers"] as? [String: String])?["Authorization"], "Bearer ${env:KABAN_RUN_TOKEN}")
        XCTAssertFalse(try read(f, "mcp-1.json").contains(try read(f, "token-1")))
        XCTAssertEqual(try read(f, "list-cwd-1"), try read(f, "cwd-1"))
        XCTAssertEqual(try read(f, "list-home-1"), try read(f, "home-1"))
        XCTAssertNotEqual(try read(f, "home-1"), FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(try read(f, "list-config-1.json"), try read(f, "mcp-1.json"))
        XCTAssertEqual(try read(f, "staged-1"), "feature.txt")
        let clone = try XCTUnwrap(f.store.getTaskDetail("config").clonePath)
        let base = try git(f.origin.path, ["rev-parse", "main"])
        let changed = try git(clone, ["diff", "--name-only", base, "HEAD"])
        XCTAssertEqual(changed, "feature.txt")
        XCTAssertEqual(try git(clone, ["show", "HEAD:.cursor/mcp.json"]), Self.projectConfig.trimmingCharacters(in: .newlines))
        let status = try read(f, "git-status-1.json"), push = try read(f, "git-push-1.json")
        XCTAssertTrue(status.contains("\"allow\":true"), status)
        XCTAssertTrue(push.contains("\"allow\":false"), push)
    }

    func testRequestHumanThroughTheHostServerWaitsForAnAnswer() throws {
        let f = try fixture()
        try "ask".write(to: f.root.appendingPathComponent("ask"), atomically: true, encoding: .utf8)
        try create(f, "ask")
        let waiting = try drive(f, "ask") { $0.machine.state == .waitingHuman(.question) }
        XCTAssertEqual(waiting.machine.stageId.rawValue, "dev")
        XCTAssertNil(waiting.machine.currentRunId)
        XCTAssertEqual(try f.store.getTaskDetail("ask").humanRequests.map(\.question), ["which file?"])
        XCTAssertEqual(try read(f, "ask-again-1.status"), "200")
    }

    func testUnexpectedServerKeepsTheRunFromStartingUntilRecheck() throws {
        let f = try fixture()
        try "kaban\tboard\ngithub\tproject\nrogue\tuser\n".write(to: f.root.appendingPathComponent("mcp-list"), atomically: true, encoding: .utf8)
        try create(f, "rogue")
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        for _ in 0..<5 { try pass(f) }
        XCTAssertEqual(try runCount(f), 0)
        XCTAssertEqual(try task(f, "rogue").machine.state.status, .queued)
        let flags = try f.store.getSnapshot().schedulerFlags
        let runs = try f.store.getTaskDetail("rogue").runs
        XCTAssertTrue(flags.contains(.projectUnavailable(project, .mcpUnexpected, detail: "rogue")), "\(flags) \(runs)")
        XCTAssertTrue(try f.store.agentProcesses().isEmpty)
        XCTAssertEqual(try task(f, "rogue").machine.attemptsUsed, 0)
        try "kaban\tboard\ngithub\tproject\n".write(to: f.root.appendingPathComponent("mcp-list"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try f.store.execute(.init(command: .recheck(scope: .project(projectId: project)))).result, .ok)
        XCTAssertFalse(try f.store.getSnapshot().schedulerFlags.contains { if case .projectUnavailable(project, _, _) = $0 { return true }; return false })
        _ = try drive(f, "rogue") { $0.machine.stageId.rawValue == "test" }
        XCTAssertGreaterThanOrEqual(try runCount(f), 1)
    }

    func testRecheckRaisesTheFlagWhenAServerAppears() throws {
        let f = try fixture()
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        try "kaban\tboard\ngithub\tproject\nrogue\tuser\n".write(to: f.root.appendingPathComponent("mcp-list"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try f.store.execute(.init(command: .recheck(scope: .project(projectId: project)))).result, .ok)
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains(.projectUnavailable(project, .mcpUnexpected, detail: "rogue")))
        try create(f, "late")
        for _ in 0..<3 { try pass(f) }
        XCTAssertEqual(try task(f, "late").machine.state.status, .queued)
        XCTAssertEqual(try runCount(f), 0)
    }

    func testRecheckUsesTheFreshCommittedStageSelection() throws {
        let f = try fixture()
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let updated = pipeline.replacingOccurrences(of: "mcp: [kaban, github, other]", with: "mcp: [kaban]")
            .replacingOccurrences(of: "mcp: [kaban, github]", with: "mcp: [kaban]")
        try updated.write(to: f.origin.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        _ = try git(f.origin.path, ["add", ".kaban/pipeline.yaml"])
        _ = try git(f.origin.path, ["commit", "-m", "Board only"])
        try "kaban\tboard\n".write(to: f.root.appendingPathComponent("mcp-list"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try f.store.execute(.init(command: .recheck(scope: .project(projectId: project)))).result, .ok)
        XCTAssertFalse(try f.store.getSnapshot().schedulerFlags.contains { if case .projectUnavailable(project, _, _) = $0 { return true }; return false })
        try create(f, "changed")
        _ = try drive(f, "changed") { $0.machine.stageId.rawValue == "test" }
        XCTAssertEqual(try runCount(f), 1)
    }

    func testDaemonHostServesTheBoardAndRejectsTokensFromBeforeTheRestart() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the host launch") }
        let f = try fixture()
        try create(f, "old")
        _ = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: "old-admit"), at: at)
        _ = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: "old-run"), at: at)
        XCTAssertEqual(try task(f, "old").machine.currentRunId, RunID(rawValue: "old-run"))
        let old = try f.store.issueRunToken(taskId: "old", at: at)
        let before = try post(f.store.mcpEndpoint!.boardURL, token: old, body: Self.initialize)
        XCTAssertEqual(before.status, "200")
        f.server.stop()

        let daemon = Process()
        daemon.executableURL = executable
        daemon.arguments = ["--stdio", "--database", f.root.appendingPathComponent("store.sqlite").path, "--workspaces", f.workspace]
        let input = Pipe(), errors = Pipe()
        daemon.standardInput = input
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = errors
        let log = LockedText()
        errors.fileHandleForReading.readabilityHandler = { handle in log.append(String(decoding: handle.availableData, as: UTF8.self)) }
        try daemon.run()
        addTeardownBlock { if daemon.isRunning { daemon.terminate() } }
        let deadline = Date().addingTimeInterval(20)
        var url: String?
        while Date() < deadline, url == nil {
            url = log.text.split(separator: "\n").first { $0.hasPrefix("KabanDaemon: board MCP ") }.map { String($0.dropFirst("KabanDaemon: board MCP ".count)) }
            if url == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        let board = try XCTUnwrap(url, log.text)
        XCTAssertTrue(board.hasPrefix("http://127.0.0.1:"), board)
        XCTAssertNotEqual(board, f.store.mcpEndpoint?.boardURL)
        XCTAssertEqual(try post(board, token: nil, body: Self.initialize).status, "401")
        XCTAssertEqual(try post(board, token: old, body: Self.initialize).status, "401")
        let complete = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"complete_stage\",\"arguments\":{\"summary\":\"stale\"}}}"
        XCTAssertEqual(try post(board, token: old, body: complete).status, "401")
        let git = try post(String(board.dropLast("/mcp".count)) + "/git/check", token: old, body: "{\"argv\":[\"status\"],\"cwd\":\"/\"}")
        XCTAssertEqual(git.status, "401")
        XCTAssertTrue(git.body.contains("\"allow\":false") && git.body.contains("unauthorized"), git.body)
        XCTAssertNotEqual(try task(f, "old").machine.currentRunId, RunID(rawValue: "old-run"))
        try input.fileHandleForWriting.close()
        daemon.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        XCTAssertEqual(daemon.terminationStatus, 0, log.text)
    }

    private static let initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"

    private final class LockedText: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        var text: String { lock.lock(); defer { lock.unlock() }; return value }
        func append(_ more: String) { lock.lock(); value += more; lock.unlock() }
    }

    private func post(_ url: String, token: String?, body: String) throws -> (status: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--max-time", "5", "-s", "-w", "\n%{http_code}", "-H", "Content-Type: application/json"] + (token.map { ["-H", "Authorization: Bearer \($0)"] } ?? []) + ["-d", body, url]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return (String(lines.last ?? ""), lines.dropLast().joined(separator: "\n"))
    }

    private struct Fixture {
        var root: URL
        var origin: URL
        var workspace: String
        var store: KabanStore
        var server: MCPBoardServer
        var agent: String
    }

    private static let projectConfig = "{\"mcpServers\":{\"github\":{\"url\":\"https://gh.example/mcp\"},\"other\":{\"command\":\"other-mcp\"}}}\n"

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-mcp-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let origin = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: origin.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: origin.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try pipeline.write(to: origin.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try "skill".write(to: origin.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try Self.projectConfig.write(to: origin.appendingPathComponent(".cursor/mcp.json"), atomically: true, encoding: .utf8)
        _ = try git(origin.path, ["init", "-b", "main"])
        _ = try git(origin.path, ["config", "user.name", "Host Test"])
        _ = try git(origin.path, ["config", "user.email", "host@example.test"])
        _ = try git(origin.path, ["add", "."])
        _ = try git(origin.path, ["commit", "-m", "Pipeline"])
        try "kaban\tboard\ngithub\tproject\n".write(to: root.appendingPathComponent("mcp-list"), atomically: true, encoding: .utf8)
        let cursor = root.appendingPathComponent("cursor-agent")
        try """
        #!/bin/sh
        R='\(root.path)'
        case "$1" in
          --version) printf 'fixture-1.0\\n' ;;
          status) printf 'ready\\n' ;;
          --list-models) printf 'explicit\\tExplicit\\n' ;;
          mcp)
            n=$(( $(cat "$R/count" 2>/dev/null || echo 0) + 1 ))
            pwd -P > "$R/list-cwd-$n"
            printf '%s' "$HOME" > "$R/list-home-$n"
            [ -f .cursor/mcp.json ] && cp .cursor/mcp.json "$R/list-config-$n.json"
            cat "$R/mcp-list" ;;
          *) exit 99 ;;
        esac
        """.write(to: cursor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cursor.path)
        let agent = root.appendingPathComponent("agent.sh")
        try agentScript(root).write(to: agent, atomically: true, encoding: .utf8)
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path, personalMCPConfig: root.appendingPathComponent("personal-mcp.json"))
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: origin.path, createTemplate: false))).result, .ok)
        _ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        XCTAssertEqual(try store.execute(.init(command: .configureCursor(environment: .init(executablePath: cursor.path)))).result, .ok)
        let project = try XCTUnwrap(store.getSnapshot().projects.first?.id)
        XCTAssertEqual(try store.execute(.init(command: .setProjectMcpAllowlist(projectId: project, servers: [McpServerRef(name: "github", source: .project)]))).result, .ok)
        let workspace = root.appendingPathComponent("workspaces")
        let server = try MCPBoardServer(store: store)
        addTeardownBlock { server.stop() }
        store.attachMCPHost(MCPHostEndpoint(port: server.port, workspaceRoot: workspace.path))
        return Fixture(root: root, origin: origin, workspace: workspace.path, store: store, server: server, agent: agent.path)
    }

    private var pipeline: String {
        """
        version: 1
        board: {max_waiting_human: 4, bounce_limit_total: 5, max_runs_per_task: 10}
        stages:
          - {id: backlog, kind: queue, on_success: dev}
          - id: dev
            kind: agent
            wip: 2
            agent: {model: explicit, skill: .kaban/dev.md, permissions: write, mcp: [kaban, github, other]}
            gates: ["/usr/bin/true"]
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: test
          - id: test
            kind: agent
            wip: 2
            agent: {model: explicit, skill: .kaban/dev.md, mcp: [kaban, github]}
            returns_to: [{stage: dev, limit: 1}]
            gates: ["/usr/bin/true"]
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review
          - {id: review, kind: human, wip: 2, on_success: merge}
          - {id: merge, kind: merge, wip: 1, on_success: done}
          - {id: done, kind: terminal}
        """
    }

    private func agentScript(_ root: URL) -> String {
        """
        R='\(root.path)'
        n=$(( $(cat "$R/count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$R/count"
        pwd -P > "$R/cwd-$n"
        printf '%s' "$HOME" > "$R/home-$n"
        cp .cursor/mcp.json "$R/mcp-$n.json"
        printf '%s' "$KABAN_RUN_TOKEN" > "$R/token-$n"
        call() {
          /usr/bin/curl --max-time 5 -s -o "$R/$2-$n.json" -w '%{http_code}' -H "Authorization: Bearer $KABAN_RUN_TOKEN" -H 'Content-Type: application/json' \\
            -d "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$n,\\"method\\":\\"tools/call\\",\\"params\\":{\\"name\\":\\"$1\\",\\"arguments\\":$3}}" "$KABAN_MCP_URL" > "$R/$2-$n.status"
        }
        check() {
          /usr/bin/curl --max-time 5 -s -o "$R/git-$1-$n.json" -H "Authorization: Bearer $KABAN_RUN_TOKEN" -H 'Content-Type: application/json' \\
            -d "{\\"argv\\":[\\"$1\\"],\\"cwd\\":\\"$PWD\\"}" "$KABAN_GIT_CHECK_URL"
        }
        call get_task_context context '{}'
        case "$(cat "$R/context-$n.json")" in
          *'"stageId":"test"'*) call return_to_stage return '{"target":"dev","issues":["again"]}'; call return_to_stage return-again '{"target":"dev","issues":["duplicate"]}'; exit 0 ;;
        esac
        if [ -f "$R/ask" ]; then call request_human ask '{"question":"which file?"}'; call request_human ask-again '{"question":"duplicate"}'; exit 0; fi
        echo "run $n" >> feature.txt
        /usr/bin/git add -A
        /usr/bin/git diff --cached --name-only > "$R/staged-$n"
        check status
        check push
        call complete_stage complete '{"summary":"done"}'
        call complete_stage complete-again '{"summary":"done twice"}'
        """
    }

    private func create(_ f: Fixture, _ id: TaskID) throws {
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let reply = try f.store.execute(.init(command: .createTask(projectId: project, title: id.rawValue, body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), makeTaskID: { id })
        XCTAssertEqual(reply.result, .taskCreated(id))
    }

    private func pass(_ f: Fixture) throws {
        try f.store.runRuntimePass(at: Date(), workspaceRoot: f.workspace, runner: "/bin/sh", runnerArguments: [f.agent])
    }

    private func drive(_ f: Fixture, _ id: TaskID, timeout: TimeInterval = 30, until done: (DurableTask) -> Bool) throws -> DurableTask {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try pass(f)
            let current = try task(f, id)
            if done(current) { return current }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let current = try task(f, id)
        XCTFail("\(id) stuck in \(current.machine.stageId.rawValue) \(current.machine.state)")
        return current
    }

    private func task(_ f: Fixture, _ id: TaskID) throws -> DurableTask {
        try XCTUnwrap(f.store.snapshot().tasks.first { $0.card.id == id })
    }

    private func runCount(_ f: Fixture) throws -> Int {
        Int((try? read(f, "count")) ?? "0") ?? 0
    }

    private func read(_ f: Fixture, _ name: String) throws -> String {
        try String(contentsOf: f.root.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func git(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        process.environment = DaemonGit.processEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(args)")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
