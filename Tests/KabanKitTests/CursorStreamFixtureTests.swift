import XCTest
import KabanProtocol
@testable import KabanKit

final class CursorStreamFixtureTests: XCTestCase {
    private func fixture(_ run: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: run, withExtension: "jsonl", subdirectory: "Fixtures/BE22")))
    }

    func testRealBE22StreamInSmallChunksKeepsToolsUsageAndSession() throws {
        let bytes = try fixture("run-1")
        var parser = CursorStreamParser()
        var events: [AgentEvent] = []
        for offset in stride(from: 0, to: bytes.count, by: 37) {
            let batch = parser.append(bytes.subdata(in: offset..<min(offset + 37, bytes.count)))
            XCTAssertEqual(batch.diagnostics, [])
            XCTAssertEqual(batch.sources.count, batch.events.count)
            events += batch.events
        }
        XCTAssertEqual(events.first, .initialized(modelName: "Grok 4.6 Medium", sessionId: "a51ce6b2-2b68-432c-80b6-afd679b03efd"))
        let tools = events.compactMap { event -> String? in
            if case .toolCall(_, let name, _) = event { return name }; return nil
        }
        XCTAssertEqual(tools, ["getMcpToolsToolCall", "globToolCall", "mcpToolCall", "editToolCall", "shellToolCall", "mcpToolCall"])
        let results = events.compactMap { event -> Bool? in
            if case .toolResult(_, let ok, _) = event { return ok }; return nil
        }
        XCTAssertEqual(results, [true, true, true, true, true, true])
        XCTAssertEqual(events.suffix(2), [.result(ok: true, durationMs: 16195), .usage(inputTokens: 7756, outputTokens: 696)])
        XCTAssertEqual(CursorLimitClassifier.failureText(stdout: String(decoding: bytes, as: UTF8.self), stderr: ""), "")
    }

    func testRealResumeHasOnlyInitAndUser() throws {
        var parser = CursorStreamParser()
        let events = parser.append(try fixture("run-2")).events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .initialized(modelName: "Grok 4.6 Medium", sessionId: "a51ce6b2-2b68-432c-80b6-afd679b03efd"))
        guard case .message(role: "user", text: _) = events[1] else { return XCTFail("Missing user context") }
    }

    func testRealCatalogConfirmsInitAndLoggedOutStatusClassifiesAuth() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "models", withExtension: "txt", subdirectory: "Fixtures/BE22"))
        let rows = try XCTUnwrap(ModelCatalogMatcher.parseListModels(String(contentsOf: url, encoding: .utf8)))
        XCTAssertEqual(ModelCatalogMatcher.observe(requestedId: "cursor-grok-4.6-medium", actualName: "Grok 4.6 Medium", rows: rows), .confirmed)
        XCTAssertEqual(rows.first { $0.id == "auto" }?.forbidden, true)
        let auth = try XCTUnwrap(Bundle.module.url(forResource: "logged-out", withExtension: "json", subdirectory: "Fixtures/BE22"))
        XCTAssertEqual(CursorLimitClassifier.classify(try String(contentsOf: auth, encoding: .utf8), pool: nil), .runnerAuth)
        XCTAssertNil(ModelCatalogMatcher.parseListModels("Available models\nexplicit - Explicit\nUnexpected diagnostic"))
    }

    func testSyntheticToolFailuresReadNestedSuccessAndMetadata() {
        var parser = CursorStreamParser()
        let batch = parser.append(Data(#"""
        {"type":"tool_call","subtype":"completed","call_id":"shell\nid","tool_call":{"completedAtMs":"1","hookAdditionalContexts":[],"shellToolCall":{"args":{"command":"false"},"result":{"success":{"exitCode":1}}}}}
        {"type":"tool_call","subtype":"completed","call_id":"mcp","tool_call":{"mcpToolCall":{"result":{"success":{"isError":true}}},"startedAtMs":"1"}}
        {"type":"tool_call","subtype":"completed","call_id":"edit","tool_call":{"editToolCall":{"result":{"error":{"message":"denied"}}}}}
        {"type":"tool_call","subtype":"completed","call_id":"ok","tool_call":{"shellToolCall":{"result":{"success":{"exitCode":0}}}}}

        """#.utf8))
        XCTAssertEqual(batch.events, [.toolResult(id: "shell\nid", ok: false, summary: "false"), .toolResult(id: "mcp", ok: false, summary: ""), .toolResult(id: "edit", ok: false, summary: ""), .toolResult(id: "ok", ok: true, summary: "")])
    }

    func testSyntheticErrorEnvelopesDoNotClassifyQuotedLimitsOrToolErrors() {
        let quoted = """
        {"type":"user","text":"usage limit spendLimitHit unauthorized"}
        {"type":"assistant","text":"rate limit"}
        {"type":"tool_call","tool_call":{"shellToolCall":{"args":{"command":"echo resource_exhausted"}}}}
        {"type":"result","subtype":"success","result":"usage limit"}
        """
        XCTAssertEqual(CursorLimitClassifier.failureText(stdout: quoted, stderr: ""), "")
        let examples: [(String, CursorLimitClass)] = [
            (#"{"type":"error","code":"rate_limit","message":"Too many requests"}"#, .rateLimit),
            (#"{"type":"result","is_error":true,"error":{"code":"spendLimitHit","message":"usage limit"}}"#, .usageExhausted(.om)),
            (#"{"type":"error","message":"resource_exhausted"}"#, .modelUnavailable),
            (#"{"type":"result","subtype":"error","result":"Authentication failed"}"#, .runnerAuth)
        ]
        for (line, expected) in examples {
            XCTAssertEqual(CursorLimitClassifier.classify(CursorLimitClassifier.failureText(stdout: quoted + "\n" + line, stderr: ""), pool: .om), expected)
        }
        XCTAssertEqual(CursorLimitClassifier.classify("Not logged in. Run agent login", pool: nil), .runnerAuth)
    }

    func testSyntheticUnterminatedResultIsFlushedAndNumericOverflowIsIgnored() {
        var parser = CursorStreamParser()
        XCTAssertEqual(parser.append(Data(#"{"type":"result","duration_ms":1e100,"usage":{"inputTokens":1,"outputTokens":true}}"#.utf8)).events, [])
        XCTAssertEqual(parser.finish().events, [.result(ok: true, durationMs: nil), .usage(inputTokens: 1, outputTokens: nil)])
        XCTAssertEqual(parser.finish().events, [])
    }
}
