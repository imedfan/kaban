import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

extension ProcessControlTests {
    private func cursorFixture(_ f: Fixture, unexpected: Bool = false) throws -> String {
        let path = try script(f, "cursor-agent", """
        #!/bin/sh
        case "$1" in
          --version) echo fixture-24; exit 0 ;;
          status) echo '{"isAuthenticated":true}'; exit 0 ;;
          --list-models) printf 'explicit\\tExplicit\\noverride-model\\tOverride\\n'; exit 0 ;;
          mcp) printf '%s' "$HOME" > '\(f.root.path)/list-home'; echo 'kaban: not loaded (needs approval)'; \(unexpected ? "echo 'personal-server: not loaded (needs approval)'" : ":"); exit 0 ;;
        esac
        printf '%s\\0' "$@" > '\(f.root.path)/argv'
        printf '%s' "$HOME" > '\(f.root.path)/home'
        printf '%s' "$XDG_CONFIG_HOME" > '\(f.root.path)/config-home'
        cp .cursor/mcp.json '\(f.root.path)/run-mcp.json'
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"fixture launch"}]}}'
        touch '\(f.root.path)/captured'
        /bin/sleep 30
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        try f.store.setRunnerExecutable(path)
        let shim = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanGitShim").resolvingSymlinksInPath()
        f.store.attachMCPHost(.init(port: 12345, workspaceRoot: f.workspace, gitShimExecutable: shim.path))
        return path
    }

    private func capturedArguments(_ f: Fixture) throws -> [String] {
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("captured").path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("captured").path) {
            let hostError = (try? String(contentsOf: f.root.appendingPathComponent("host.err"), encoding: .utf8)) ?? ""
            XCTFail("Cursor did not launch. Host: \(hostError), state: \(try f.store.snapshot().tasks.map { "\($0.card.id) \($0.machine.stageId): \($0.machine.state)" })")
        }
        let data = try Data(contentsOf: f.root.appendingPathComponent("argv"))
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    func testConfiguredCursorReceivesFrozenPromptOverrideAndRunHome() throws {
        let f = try fixture()
        _ = try cursorFixture(f)
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        _ = try f.store.execute(.init(command: .createTask(projectId: project, title: "Frozen title", body: "Task body\n\n## Критерии приёмки\n- [ ] Exact criterion")), makeTaskID: { "cursor" })
        XCTAssertEqual(try f.store.execute(.init(command: .setModelOverride(taskId: "cursor", stageId: "dev", model: "override-model"))).result, .ok)
        try f.store.database.write { db in
            var detail = try KabanStore.detail("cursor", db: db)
            detail.artifacts.append(.init(id: "summary", taskId: "cursor", runId: "previous", stageId: "inspect", kind: "summary", text: "Previous handoff", createdAt: at))
            detail.artifacts.append(.init(id: "diff", taskId: "cursor", stageId: "inspect", kind: "diffstat", text: "feature.swift | 7 +++++++", createdAt: at))
            detail.artifacts.append(.init(id: "gate", taskId: "cursor", stageId: "inspect", kind: "gate_output", text: "Earlier gates passed", createdAt: at))
            try KabanStore.saveDetail(detail, taskId: "cursor", db: db)
        }
        _ = try f.store.tick(tickId: UUID(), runId: "admit", at: at)
        try f.store.database.write { db in
            var task = try KabanStore.task("cursor", db: db)
            task.machine.pendingPrompt = [.gateOutput("Fix failing gate"), .humanComments("Human note"), .returnIssues(from: "inspect", issues: ["Return issue"])]
            try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try KabanStore.encode(task), "cursor"])
        }
        _ = try f.store.tick(tickId: UUID(), runId: "cursor-run", at: at)
        // Change the working skill after reservation; the launch must use its pipeline snapshot.
        try "WRONG mutable skill".write(toFile: f.origin + "/.kaban/dev.md", atomically: true, encoding: .utf8)
        try f.store.queueGitGrantNotice(taskId: "cursor", argv: ["rebase", "HEAD~1"], at: at)
        _ = try f.store.runClonePass(owner: "test", at: at, workspaceRoot: f.workspace)
        try f.store.runRuntimePass(at: at, workspaceRoot: f.workspace)
        let args = try capturedArguments(f)
        XCTAssertEqual(Array(args.dropLast()), ["-p", "--output-format", "stream-json", "--model", "override-model", "--trust", "--approve-mcps", "--force"])
        let prompt = try XCTUnwrap(args.last)
        for input in ["Skill:\nskill", "Frozen title", "Exact criterion", "Previous handoff", "feature.swift | 7 +++++++", "Earlier gates passed", "Fix failing gate", "Human note", "Return issue", "git_grants:\nrebase HEAD~1 разрешена один раз", "report_progress", "complete_stage"] {
            XCTAssertTrue(prompt.contains(input), "Missing input: \(input)")
        }
        XCTAssertFalse(prompt.contains("WRONG mutable skill"))
        let home = try String(contentsOf: f.root.appendingPathComponent("home"), encoding: .utf8)
        XCTAssertTrue(home.hasPrefix(f.workspace + "/mcp-homes/"))
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("list-home"), encoding: .utf8), home)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("config-home"), encoding: .utf8), home + "/.config")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.cursor/mcp.json"))
        let delivery = try XCTUnwrap(f.store.getTaskDetail("cursor").gitGrants.first?.delivery)
        XCTAssertEqual(delivery.via, .nextPrompt)
        XCTAssertEqual(delivery.runId, "cursor-run")
        let seq = try f.store.getSnapshot().seq
        try f.store.runRuntimePass(at: at, workspaceRoot: f.workspace)
        XCTAssertEqual(try f.store.agentProcesses().count, 1)
        XCTAssertEqual(try f.store.getSnapshot().seq, seq)
        XCTAssertNil(try f.store.getTaskDetail("cursor").gitGrants.first?.consumption)
    }

    func testLegacyTaskWithoutDetailStillFreezesItsPipeline() throws {
        let f = try fixture()
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        _ = try f.store.execute(.init(command: .createTask(projectId: project, title: "Legacy", body: "Task\n\n## Критерии приёмки\nReady")), makeTaskID: { "legacy-cursor" })
        _ = try f.store.tick(tickId: UUID(), runId: "admit", at: at)
        try f.store.database.write { db in try db.execute(sql: "DELETE FROM task_detail WHERE task_id = 'legacy-cursor'") }
        _ = try f.store.tick(tickId: UUID(), runId: "legacy-run", at: at)
        let spec = try XCTUnwrap(f.store.getRunSpec("legacy-run"))
        XCTAssertEqual(spec.stageId, "dev")
        XCTAssertEqual(spec.pipeline.stage("dev")?.agent?.model, "explicit")
        XCTAssertNil(spec.promptParts)
        XCTAssertEqual(try task(f, "legacy-cursor").machine.state, .running)
    }

    func testStartUsesBoundPipelineModelWhenNoOverrideExists() throws {
        let f = try fixture()
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        _ = try f.store.execute(.init(command: .createTask(projectId: project, title: "Reload", body: "Task\n\n## Критерии приёмки\nReady")), makeTaskID: { "rebound-model" })
        _ = try f.store.tick(tickId: UUID(), runId: "admit", at: at)
        try f.store.database.write { db in
            var task = try KabanStore.task("rebound-model", db: db)
            let index = try XCTUnwrap(task.pipeline.index(of: "dev"))
            task.pipeline.stages[index].agent?.model = "stale-model"
            try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try KabanStore.encode(task), "rebound-model"])
        }
        _ = try f.store.tick(tickId: UUID(), runId: "rebound-run", at: at)
        let request = try XCTUnwrap(f.store.pendingEffectItems().compactMap { item -> AgentRunRequest? in
            if case .startAgentRun(let request) = item.effect, request.runId == "rebound-run" { return request }
            return nil
        }.first)
        XCTAssertEqual(request.model, "explicit")
        XCTAssertEqual(try f.store.getRunSpec("rebound-run")?.pipeline.stage("dev")?.agent?.model, "explicit")
    }

    func testGrantJournalFailureKeepsExecGateClosed() throws {
        let f = try fixture()
        _ = try cursorFixture(f)
        _ = try launch(f, "delivery-failure")
        try f.store.queueGitGrantNotice(taskId: "delivery-failure", argv: ["stash"], at: at)
        _ = try f.store.runClonePass(owner: "test", at: at, workspaceRoot: f.workspace)
        // Token issuance and MCP preflight journal first; reject only the grant handoff.
        try f.store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_grant_delivery BEFORE UPDATE ON event WHEN CAST(NEW.payload AS TEXT) LIKE '%gitGrantDelivered%' BEGIN SELECT RAISE(ABORT, 'delivery failed'); END")
        }
        XCTAssertThrowsError(try f.store.runProcessPass(owner: "test", at: at, workspaceRoot: f.workspace, runner: nil, launchConfiguredCursor: true))
        XCTAssertTrue(try f.store.agentProcesses().isEmpty)
        XCTAssertNil(try f.store.getTaskDetail("delivery-failure").gitGrants.first?.delivery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("captured").path))
    }

    func testDaemonWithoutRunnerLaunchesConfiguredCursor() throws {
        let f = try fixture()
        _ = try cursorFixture(f)
        f.store.attachMCPHost(nil)
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        _ = try f.store.execute(.init(command: .createTask(projectId: project, title: "Daemon task", body: "Task\n\n## Критерии приёмки\n- [ ] Daemon criterion")), makeTaskID: { "host-cursor" })
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon").resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let host = Process()
        host.executableURL = binary
        host.arguments = ["--stdio", "--database", f.path, "--workspaces", f.workspace]
        let input = Pipe()
        host.standardInput = input
        host.standardOutput = FileHandle.nullDevice
        let errorURL = f.root.appendingPathComponent("host.err")
        FileManager.default.createFile(atPath: errorURL.path, contents: Data())
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? error.close() }
        host.standardError = error
        try host.run()
        defer {
            try? input.fileHandleForWriting.close()
            if host.isRunning { host.terminate() }
            host.waitUntilExit()

        }
        let args = try capturedArguments(f)
        XCTAssertEqual(Array(args.prefix(5)), ["-p", "--output-format", "stream-json", "--model", "explicit"])
        XCTAssertTrue(try XCTUnwrap(args.last).contains("Daemon criterion"))
        XCTAssertTrue(host.isRunning)
    }

    func testUnexpectedMCPBlocksConfiguredCursorAndDoesNotDeliverGrants() throws {
        let f = try fixture()
        _ = try cursorFixture(f, unexpected: true)
        _ = try launch(f, "blocked-cursor")
        try f.store.queueGitGrantNotice(taskId: "blocked-cursor", argv: ["stash"], at: at)
        _ = try f.store.runClonePass(owner: "test", at: at, workspaceRoot: f.workspace)
        _ = try f.store.runProcessPass(owner: "test", at: at, workspaceRoot: f.workspace, runner: nil, launchConfiguredCursor: true)
        XCTAssertEqual(try task(f, "blocked-cursor").machine.state, .queued(nil))
        XCTAssertTrue(try f.store.agentProcesses().isEmpty)
        XCTAssertNil(try f.store.getTaskDetail("blocked-cursor").gitGrants.first?.delivery)
    }
}
