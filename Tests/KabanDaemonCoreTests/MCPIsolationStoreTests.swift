import XCTest
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class MCPIsolationStoreTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)
    private let board = "http://127.0.0.1:9/mcp"
    private let body = "Task\n\n## Критерии приёмки\n- [ ] Ready\n"

    func testBlockedPreflightRejectsTheNextStart() throws {
        let fixture = try store()
        try queuedAgent(fixture.store)
        let unexpected = try fixture.store.applyMCPPreflight(taskId: "a", definitions: [], boardURL: board, listOutput: "kaban\tboard\nother\tparent\n", listExit: 0, at: at)
        XCTAssertEqual(unexpected.block, .unexpected("other"))
        XCTAssertFalse(unexpected.configJSON.contains("--approve-mcps"))
        XCTAssertThrowsError(try fixture.store.apply(.start(RunID(rawValue: "run-a")), taskId: "a", commandId: UUID(), at: at)) { error in
            guard case StoreError.rejected(let command) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(command.code, "mcp_unexpected")
            XCTAssertEqual(command.message, "other")
        }
        XCTAssertEqual(try task("a", fixture.store).machine.state.status, .queued)
        let broken = try fixture.store.applyMCPPreflight(taskId: "a", definitions: [], boardURL: board, listOutput: "", listExit: 2, at: at)
        XCTAssertEqual(broken.block, .unresolvable("mcp list"))
        XCTAssertThrowsError(try fixture.store.apply(.start(RunID(rawValue: "run-a")), taskId: "a", commandId: UUID(), at: at))
    }

    func testWarningAllowsTheBoardAndACleanListStarts() throws {
        let fixture = try store(mcp: "[kaban, github]")
        try queuedAgent(fixture.store)
        let decision = try fixture.store.applyMCPPreflight(taskId: "a", definitions: [MCPServerDefinition(name: "github", source: "project", endpoint: "npx")], boardURL: board, listOutput: "kaban\tboard\n", listExit: 0, at: at)
        XCTAssertEqual(decision.warnings, ["mcp_not_allowlisted:github"])
        XCTAssertNil(decision.block)
        let object = try JSONSerialization.jsonObject(with: Data(decision.configJSON.utf8)) as? [String: Any]
        let servers = object?["mcpServers"] as? [String: Any]
        XCTAssertEqual(servers?.keys.sorted(), ["kaban"])
        _ = try fixture.store.apply(.start(RunID(rawValue: "run-a")), taskId: "a", commandId: UUID(), at: at)
        XCTAssertEqual(try task("a", fixture.store).machine.state, .running)
    }

    func testRecoveryRemovesTheSwappedFileFromTheDiff() throws {
        let fixture = try store()
        let clone = try gitClone()
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        let original = "{\"mcpServers\":{}}\n"
        try Data(original.utf8).write(to: clone.appendingPathComponent(".cursor/mcp.json"))
        _ = try git(["add", ".cursor/mcp.json"], clone)
        _ = try git(["commit", "-m", "config"], clone)
        try fixture.store.installMCPConfig(taskId: "a", cloneRoot: clone, generated: "{\"mcpServers\":{\"kaban\":{\"url\":\"\(board)\"}}}")
        XCTAssertFalse(try git(["diff", "--", ".cursor/mcp.json"], clone).isEmpty)
        _ = try fixture.store.recover(passId: UUID(), at: at)
        XCTAssertEqual(try git(["diff", "--", ".cursor/mcp.json"], clone), "")
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent(".cursor/mcp.json"), encoding: .utf8), original)
    }

    func testDaemonPrintsOneMCPRestoreTwice() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the isolation launch") }
        let fixture = try store()
        let clone = try gitClone()
        try fixture.store.installMCPConfig(taskId: "a", cloneRoot: clone, generated: "{\"mcpServers\":{\"kaban\":{\"url\":\"\(board)\"}}}")
        let first = try runDaemon(executable, database: fixture.path)
        let second = try runDaemon(executable, database: fixture.path)
        XCTAssertEqual(first.exit, 0, first.stderr)
        XCTAssertEqual(second.exit, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        XCTAssertEqual(first.stderr, "mcp restore a clean\n")
        XCTAssertEqual(try git(["status", "--porcelain"], clone), "")
        if let root = ProcessInfo.processInfo.environment["KABAN_PROCESS_EVIDENCE"].map(URL.init(fileURLWithPath:)) {
            try first.stderr.write(to: root.appendingPathComponent("be-10-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-10-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    private func store(mcp: String = "[kaban]") throws -> (path: String, store: KabanStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let opened = try KabanStore(path: path)
        let pipeline = PipelineValidator.validate(yaml: """
        version: 1
        board: {max_waiting_human: 2, bounce_limit_total: 5, max_runs_per_task: 12}
        stages:
          - {id: queue, name: Queue, kind: queue, on_success: agent}
          - id: agent
            name: Agent
            kind: agent
            wip: 2
            agent: {harness: cursor-cli, model: fake, skill: test.md, permissions: write, mcp: \(mcp)}
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review
          - {id: review, name: Review, kind: human, wip: 1, on_success: done}
          - {id: done, name: Done, kind: terminal}
        """)
        XCTAssertTrue(pipeline.errors.allSatisfy { $0.code == "merge_count" }, "\(pipeline.errors)")
        _ = try opened.registerProject(ProjectSummary(id: "p", name: "P", path: root.path, mascotSeed: "p"), pipeline: try XCTUnwrap(pipeline.config), commandId: UUID(), at: at)
        _ = try opened.setSettings(GlobalSettings(maxConcurrentRuns: 4, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at)
        _ = try opened.execute(.init(command: .createTask(projectId: "p", title: "a", body: body)), now: { at }, makeTaskID: { "a" })
        return (path, opened)
    }

    private func queuedAgent(_ store: KabanStore) throws {
        _ = try store.apply(.start(RunID(rawValue: "intake-a")), taskId: "a", commandId: UUID(), at: at)
        XCTAssertEqual(try task("a", store).machine.stageId.rawValue, "agent")
        XCTAssertEqual(try task("a", store).machine.state.status, .queued)
    }

    private func task(_ id: TaskID, _ store: KabanStore) throws -> DurableTask {
        try store.database.read { try KabanStore.task(id, db: $0) }
    }

    private func gitClone() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try git(["init"], root)
        _ = try git(["config", "user.email", "probe@example.com"], root)
        _ = try git(["config", "user.name", "Probe"], root)
        try Data("readme\n".utf8).write(to: root.appendingPathComponent("README"))
        _ = try git(["add", "README"], root)
        _ = try git(["commit", "-m", "init"], root)
        return root
    }

    private func git(_ arguments: [String], _ root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return text
    }

    private struct DaemonOutput { var exit: Int32; var stderr: String }
    private func runDaemon(_ binary: URL, database: String) throws -> DaemonOutput {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--mcp-isolation-pass", "--stdio", "--database", database]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return DaemonOutput(exit: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
