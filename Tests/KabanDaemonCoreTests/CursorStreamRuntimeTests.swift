import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

extension ProcessControlTests {
    private func streamCursor(_ f: Fixture, name: String, afterInit: String = "/bin/sleep 30") throws {
        let path = try script(f, "stream-cursor", """
        #!/bin/sh
        case "$1" in
          --version) echo fixture-25; exit 0 ;;
          status) echo '{"isAuthenticated":true}'; exit 0 ;;
          --list-models) printf 'explicit\\tExplicit\\nother\\tOther\\n'; exit 0 ;;
          mcp) echo 'kaban: not loaded (needs approval)'; exit 0 ;;
        esac
        echo '{"type":"system","subtype":"init","model":"\(name)","session_id":"session-25"}'
        \(afterInit)
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        try f.store.setRunnerExecutable(path)
        XCTAssertTrue(try f.store.replaceCatalog(text: "explicit\tExplicit\nother\tOther\n", at: at))
        let shim = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanGitShim").resolvingSymlinksInPath()
        f.store.attachMCPHost(.init(port: 12345, workspaceRoot: f.workspace, gitShimExecutable: shim.path))
    }

    private func configuredPass(_ f: Fixture) throws {
        _ = try f.store.runProcessPass(owner: "stream-test", at: at, workspaceRoot: f.workspace, runner: nil, launchConfiguredCursor: true)
    }

    private func awaitStream(_ f: Fixture, until predicate: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try configuredPass(f)
            if try predicate() { return }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        XCTFail("Stream observation timed out")
    }

    func testConfiguredStreamMismatchStopsProcessAndRefundsFrozenModelAfterReopen() throws {
        let f = try fixture()
        try streamCursor(f, name: "Other", afterInit: """
        /bin/sleep 3
        touch .tool-ran
        /bin/sleep 30
        """)
        let run = try launch(f, "mismatch")
        _ = try f.store.prepareTaskClone(taskId: "mismatch", at: at, workspaceRoot: f.workspace)
        try awaitStream(f) { try self.task(f, "mismatch").machine.state == .waitingHuman(.modelSubstituted) }
        let process = try XCTUnwrap(f.store.agentProcesses().first { $0.runId == run })
        XCTAssertEqual(process.state, "stopped")
        XCTAssertEqual(process.sessionId, "session-25")
        XCTAssertFalse(isRunning(process.pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(f.store.getTaskDetail("mismatch").clonePath) + "/.tool-ran"))
        let state = try task(f, "mismatch").machine
        XCTAssertEqual(state.attemptsUsed, 0)
        XCTAssertEqual(state.runsSinceHuman, 0)
        let detail = try f.store.getTaskDetail("mismatch")
        XCTAssertEqual(detail.runs.first?.endReason, .modelSubstituted)
        XCTAssertEqual(detail.runs.first?.countsTowardLimits, false)
        XCTAssertEqual(detail.runs.first?.actualModelName, "Other")
        let reopened = try KabanStore(path: f.path)
        XCTAssertEqual(try reopened.getTaskDetail("mismatch").task.state, .waitingHuman(.modelSubstituted))
        let flag = try XCTUnwrap(reopened.getSnapshot().modelFlags.first)
        XCTAssertEqual(flag.modelId, "explicit")
        XCTAssertEqual(flag.reason, .substituted)
        XCTAssertEqual(flag.requested, "Explicit")
        XCTAssertEqual(flag.actual, "Other")
        _ = try reopened.apply(.completeStage(run, summary: "late"), taskId: "mismatch", commandId: UUID(), at: at)
        XCTAssertEqual(try reopened.getTaskDetail("mismatch").task.state, .waitingHuman(.modelSubstituted))
    }

    func testFastMCPCompletionObservesMismatchBeforePeriodicPoll() throws {
        let f = try fixture()
        try streamCursor(f, name: "Other", afterInit: "touch .init-written\n/bin/sleep 30")
        _ = try launch(f, "fast")
        _ = try f.store.prepareTaskClone(taskId: "fast", at: at, workspaceRoot: f.workspace)
        try configuredPass(f)
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: try XCTUnwrap(f.store.getTaskDetail("fast").clonePath) + "/.init-written"), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let token = try f.store.issueRunToken(taskId: "fast", at: at)
        XCTAssertThrowsError(try f.store.performBoardTool(token: token, name: "complete_stage", arguments: ["summary": "must not succeed"], at: at))
        XCTAssertEqual(try task(f, "fast").machine.state, .waitingHuman(.modelSubstituted))
        XCTAssertEqual(try f.store.agentProcesses().first?.state, "stopped")
        XCTAssertEqual(try f.store.getTaskDetail("fast").runs.first?.endReason, .modelSubstituted)
    }

    func testIngestionFailureRollsBackMismatchMarkerJournalAndKillOutbox() throws {
        let f = try fixture()
        let run = try launch(f, "atomic")
        XCTAssertTrue(try f.store.replaceCatalog(text: "explicit\tExplicit\nother\tOther\n", at: at))
        let before = try f.store.getSnapshot()
        try f.store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_stream BEFORE INSERT ON run_log_event BEGIN SELECT RAISE(ABORT, 'test write failure'); END")
        }
        let chunk = Data("{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"Other\"}\n".utf8)
        XCTAssertThrowsError(try f.store.ingestAgentOutput(runId: run, taskId: "atomic", chunk: chunk, directory: f.workspace, at: at))
        XCTAssertEqual(try task(f, "atomic").machine.state, .running)
        XCTAssertEqual(try f.store.getSnapshot().seq, before.seq)
        XCTAssertEqual(try f.store.getSnapshot().modelFlags, [])
        try f.store.database.write { db in try db.execute(sql: "DROP TRIGGER fail_stream") }
        let reopened = try KabanStore(path: f.path)
        try reopened.ingestAgentOutput(runId: run, taskId: "atomic", chunk: chunk, directory: f.workspace, at: at)
        XCTAssertEqual(try reopened.getTaskDetail("atomic").task.state, .waitingHuman(.modelSubstituted))
        XCTAssertTrue(try reopened.pendingEffectItems().contains { if case .killRun(run) = $0.effect { true } else { false } })
    }

    func testUnknownFirstInitContinuesAndLaterInitDoesNotCreateMismatch() throws {
        let f = try fixture()
        try streamCursor(f, name: "Unknown")
        let run = try launch(f, "unconfirmed")
        _ = try f.store.prepareTaskClone(taskId: "unconfirmed", at: at, workspaceRoot: f.workspace)
        try awaitStream(f) { try f.store.getTaskDetail("unconfirmed").feed.contains { $0.kind == "model_unconfirmed" } }
        XCTAssertEqual(try task(f, "unconfirmed").machine.state, .running)
        XCTAssertEqual(try f.store.agentProcesses().first?.state, "running")
        let reopened = try KabanStore(path: f.path)
        try reopened.ingestAgentOutput(runId: run, taskId: "unconfirmed", chunk: Data("{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"Other\"}\n".utf8), directory: f.workspace, at: at)
        XCTAssertEqual(try reopened.getTaskDetail("unconfirmed").feed.filter { $0.kind == "model_unconfirmed" }.count, 1)
        XCTAssertEqual(try reopened.getTaskDetail("unconfirmed").runs.first?.actualModelName, "Unknown")
        XCTAssertEqual(try reopened.getTaskDetail("unconfirmed").task.state, .running)
        XCTAssertEqual(try reopened.getSnapshot().modelFlags, [])
    }

    func testStreamUsesFrozenRequestedModelNotChangedOverrideAndFlushesPartialInit() throws {
        let f = try fixture()
        let run = try launch(f, "frozen")
        XCTAssertTrue(try f.store.replaceCatalog(text: "explicit\tExplicit\nother\tOther\n", at: at))
        _ = try f.store.execute(.init(command: .setModelOverride(taskId: "frozen", stageId: "dev", model: "other")), now: { self.at })
        let chunk = Data(#"{"type":"system","subtype":"init","model":"Explicit"}"#.utf8)
        try f.store.ingestAgentOutput(runId: run, taskId: "frozen", chunk: chunk.prefix(18), directory: f.workspace, at: at)
        let reopened = try KabanStore(path: f.path)
        try reopened.ingestAgentOutput(runId: run, taskId: "frozen", chunk: chunk.dropFirst(18), complete: true, directory: f.workspace, at: at)
        XCTAssertEqual(try reopened.getTaskDetail("frozen").runs.first?.actualModelName, "Explicit")
        XCTAssertEqual(try reopened.getTaskDetail("frozen").task.state, .running)
        XCTAssertEqual(try reopened.getSnapshot().modelFlags, [])
    }

    func testSyntheticStreamLimitsAndSilentInitReleaseWithoutCharging() throws {
        let cases: [(String, String, TaskState)] = [
            ("rate", #"{"type":"error","code":"rate_limit","message":"Too many requests"}"#, .retryWait(.rateLimit)),
            ("usage", #"{"type":"result","is_error":true,"error":"spendLimitHit"}"#, .queued(.quotaOm)),
            ("model", #"{"type":"error","message":"resource_exhausted"}"#, .queued(.modelFlag)),
            ("auth", #"{"type":"error","message":"Authentication failed"}"#, .retryWait(.runnerAuth)),
            ("silent", "", .retryWait(.silentExit)),
            ("silent-nonzero", "", .retryWait(.silentExit))
        ]
        for (id, error, expected) in cases {
            let f = try fixture()
            try streamCursor(f, name: "Explicit", afterInit: """
            echo '{"type":"user","text":"\(String(repeating: "context ", count: 800))quoted rate limit usage limit resource_exhausted unauthorized"}'
            \(error.isEmpty ? ":" : "echo '\(error)'")
            exit \(id == "silent-nonzero" ? 7 : 0)
            """)
            let taskId = TaskID(rawValue: id)
            let run = try launch(f, taskId)
            _ = try f.store.prepareTaskClone(taskId: taskId, at: at, workspaceRoot: f.workspace)
            try awaitStream(f) { try self.task(f, taskId).machine.state != .running }
            XCTAssertEqual(try task(f, taskId).machine.state, expected, id)
            XCTAssertEqual(try task(f, taskId).machine.attemptsUsed, 0, id)
            XCTAssertEqual(try task(f, taskId).machine.runsSinceHuman, 0, id)
            XCTAssertEqual(try summary(f, taskId, run).countsTowardLimits, false, id)
            let snapshot = try KabanStore(path: f.path).getSnapshot()
            switch id {
            case "rate": XCTAssertTrue(snapshot.schedulerFlags.contains { if case .rateLimited = $0 { true } else { false } })
            case "usage": XCTAssertTrue(snapshot.schedulerFlags.contains { if case .poolUsageExhausted(.om, _) = $0 { true } else { false } })
            case "model": XCTAssertEqual(snapshot.modelFlags.first?.reason, .unavailable)
            case "auth": XCTAssertTrue(snapshot.schedulerFlags.contains(.runnerUnavailable(.runnerAuth)))
            default: XCTAssertEqual(snapshot.schedulerFlags, [])
            }
        }
    }
}
