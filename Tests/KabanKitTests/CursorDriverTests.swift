import XCTest
import KabanProtocol
@testable import KabanKit

final class CursorDriverTests: XCTestCase {
    func testUnknownMalformedPartialAndOversizedLinesStayBounded() {
        var parser = CursorStreamParser()
        let valid = Data("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}\n".utf8)
        let split = valid.count / 2
        XCTAssertTrue(parser.append(valid.prefix(split)).events.isEmpty)
        let continued = parser.append(valid.dropFirst(split))
        XCTAssertEqual(continued.events, [.message(role: "assistant", text: "hello")])
        XCTAssertTrue(continued.diagnostics.isEmpty)

        let mixed = Data("""
        {"type":"widget","subtype":"spin"}
        {not-json}
        {"type":"result","subtype":"success","is_error":false,"duration_ms":12}

        """.utf8)
        let batch = parser.append(mixed)
        XCTAssertEqual(batch.events, [.result(ok: true, durationMs: 12)])
        XCTAssertEqual(batch.diagnostics.map(\.kind), [.unknown, .malformed])

        var huge = Data(repeating: UInt8(ascii: "{"), count: CursorStreamParser.maxLineBytes + 32)
        huge.append(contentsOf: Data("\n{\"type\":\"user\",\"text\":\"after\"}\n".utf8))
        let bounded = parser.append(huge)
        XCTAssertEqual(bounded.diagnostics.map(\.kind), [.oversized])
        XCTAssertEqual(bounded.events, [.message(role: "user", text: "after")])
        XCTAssertLessThanOrEqual(huge.count, CursorStreamParser.maxLineBytes + 80)
    }

    func testInitSessionIsNotInventedAndUsageIsNotZero() {
        var parser = CursorStreamParser()
        let batch = parser.append(Data("""
        {"type":"system","subtype":"init","model":"Composer","session_id":""}
        {"type":"system","subtype":"init","model":"Composer","session_id":"sess-1"}
        {"type":"result","session_id":"from-result","is_error":false}
        {"type":"result","is_error":true,"usage":{"output_tokens":4}}

        """.utf8))
        XCTAssertEqual(batch.events[0], .initialized(modelName: "Composer", sessionId: nil))
        XCTAssertEqual(batch.events[1], .initialized(modelName: "Composer", sessionId: "sess-1"))
        XCTAssertEqual(parser.observedSessionId, "sess-1")
        XCTAssertEqual(batch.events[2], .result(ok: true, durationMs: nil))
        XCTAssertEqual(batch.events[3], .result(ok: false, durationMs: nil))
        XCTAssertEqual(batch.events[4], .usage(inputTokens: nil, outputTokens: 4))
        XCTAssertFalse(batch.events.contains(.usage(inputTokens: 0, outputTokens: 0)))
    }

    func testModelIsRequiredAndUnverifiedResumeKeepsContextWithoutASessionId() throws {
        XCTAssertThrowsError(try CursorLaunch.plan(model: " ", readOnly: true, resumeRequested: false, verifiedSessionId: nil, prompt: "x", environment: [:])) {
            XCTAssertEqual($0 as? CursorLaunchFailure, .modelRequired)
        }
        XCTAssertThrowsError(try CursorLaunch.plan(model: "auto", readOnly: false, resumeRequested: true, verifiedSessionId: "sess-1", prompt: "x", environment: [:])) {
            XCTAssertEqual($0 as? CursorLaunchFailure, .modelRequired)
        }
        XCTAssertThrowsError(try CursorLaunch.plan(model: "<model-id>", readOnly: true, resumeRequested: false, verifiedSessionId: nil, prompt: "x", environment: [:])) {
            XCTAssertEqual($0 as? CursorLaunchFailure, .modelRequired)
        }
        let prompt = CursorLaunch.render(CursorPromptParts(skill: "be careful", title: "Fix the gate", body: "## Критерии приёмки\nworks", handoff: "left the clone dirty", additions: [.humanAnswer("use the saved note")], grants: ["git status"]))
        let secret = "cursor-secret-value"
        let fresh = try CursorLaunch.plan(model: " composer-2 ", readOnly: true, resumeRequested: true, verifiedSessionId: nil, prompt: prompt, environment: ["CURSOR_API_KEY": secret, "PATH": "/usr/bin"])
        XCTAssertEqual(fresh.arguments.prefix(5).map { $0 }, ["-p", "--output-format", "stream-json", "--model", "composer-2"])
        XCTAssertFalse(fresh.arguments.contains("--resume"))
        XCTAssertFalse(fresh.arguments.contains("--force"))
        XCTAssertFalse(fresh.arguments.contains("--approve-mcps"))
        XCTAssertNil(fresh.sessionId)
        XCTAssertTrue(fresh.prompt.contains("be careful"))
        XCTAssertTrue(fresh.prompt.contains("use the saved note"))
        XCTAssertTrue(fresh.prompt.contains("complete_stage"))
        XCTAssertFalse(fresh.arguments.joined(separator: "\n").contains(secret))
        XCTAssertFalse(fresh.prompt.contains(secret))
        XCTAssertEqual(fresh.redactedEnvironment["CURSOR_API_KEY"], "<redacted>")
        XCTAssertFalse(fresh.redactedEnvironment.values.contains(secret))

        let resumed = try CursorLaunch.plan(model: "composer-2", readOnly: false, resumeRequested: true, verifiedSessionId: "sess-1", prompt: prompt, environment: [:])
        XCTAssertEqual(resumed.sessionId, "sess-1")
        XCTAssertTrue(resumed.arguments.contains("--model"))
        XCTAssertEqual(resumed.arguments.dropLast().suffix(3).map { $0 }, ["--force", "--resume", "sess-1"])
        let blank = try CursorLaunch.plan(model: "composer-2", readOnly: false, resumeRequested: true, verifiedSessionId: "  ", prompt: prompt, environment: [:])
        XCTAssertNil(blank.sessionId)
        XCTAssertFalse(blank.arguments.contains("--resume"))
    }

    func testRunnerAssessmentUsesTheExecutableAndDoesNotGuessALogin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-cursor-kit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(CursorRunner.assess(executable: root.appendingPathComponent("missing").path, environment: [:]).reason, .agentMissing)
        let inert = root.appendingPathComponent("inert")
        try "echo should-not-run\n".write(to: inert, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: inert.path)
        XCTAssertEqual(CursorRunner.assess(executable: inert.path, environment: [:]).reason, .agentNotRunnable)
        XCTAssertNil(CursorRunner.loginFailure(in: "connection refused"))
        let script = try executable(root, """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo probe-1.0; exit 0; fi
        if [ "$1" = "--list-models" ]; then echo "composer-2 - Composer"; exit 0; fi
        echo "not logged in"
        exit 1
        """)
        let loggedOut = CursorRunner.assess(executable: script.path, environment: ["PATH": "/bin:/usr/bin"])
        XCTAssertEqual(loggedOut.reason, .agentNotLoggedIn)
        XCTAssertEqual(loggedOut.version, "probe-1.0")
        XCTAssertEqual(loggedOut.limitsNote, "composer-2 - Composer")
        let auth = try executable(root, """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo probe-1.0; exit 0; fi
        if [ "$1" = "--list-models" ]; then echo "composer-2 - Composer"; exit 0; fi
        echo "authentication failed"
        exit 1
        """)
        XCTAssertEqual(CursorRunner.assess(executable: auth.path, environment: ["PATH": "/bin:/usr/bin"]).reason, .runnerAuth)
    }

    private func executable(_ root: URL, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
