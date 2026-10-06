import XCTest
import KabanProtocol
@testable import KabanKit

final class ModelCatalogTests: XCTestCase {
    func testUnknownMalformedAndAmbiguousNamesAreNotMatches() {
        let rows = [
            ModelInfo(id: "composer-2", name: "Composer 2", pool: .cm),
            ModelInfo(id: "gpt-5", name: "GPT-5", pool: .om),
            ModelInfo(id: "alias-a", name: "Same", pool: .om),
            ModelInfo(id: "alias-b", name: "Same", pool: .om)
        ]
        XCTAssertEqual(ModelCatalogMatcher.observe(requestedId: "composer-2", actualName: "Composer 2", rows: rows), .confirmed)
        XCTAssertEqual(ModelCatalogMatcher.observe(requestedId: "composer-2", actualName: "GPT-5", rows: rows), .substituted(requestedName: "Composer 2", actualName: "GPT-5"))
        XCTAssertEqual(ModelCatalogMatcher.observe(requestedId: "composer-2", actualName: "Mystery", rows: rows), .unconfirmed)
        XCTAssertEqual(ModelCatalogMatcher.observe(requestedId: "alias-a", actualName: "Same", rows: rows), .unconfirmed)
        XCTAssertEqual(ModelCatalogMatcher.observe(requestedId: "missing", actualName: "GPT-5", rows: rows), .unconfirmed)
        XCTAssertEqual(ModelCatalogMatcher.observe(requestedId: "composer-2", actualName: " ", rows: rows), .unconfirmed)
        XCTAssertFalse(rows.contains { $0.id.rawValue == "Mystery" })
    }

    func testListModelsTextDoesNotInventRowsFromAnAuthError() {
        let auth = "Error: Authentication required. Run 'agent login', pass --api-key/--auth-token, or set CURSOR_API_KEY/CURSOR_AUTH_TOKEN.\n"
        XCTAssertNil(ModelCatalogMatcher.parseListModels(auth))
        XCTAssertNil(ModelCatalogMatcher.parseListModels(""))
        XCTAssertNil(ModelCatalogMatcher.parseListModels("composer-2 Composer 2\n"))
        let parsed = ModelCatalogMatcher.parseListModels("composer-2\tComposer 2\ngpt-5\tGPT-5\nauto\tAuto\n")
        XCTAssertEqual(parsed?.map(\.id.rawValue), ["composer-2", "gpt-5", "auto"])
        XCTAssertEqual(parsed?.first { $0.id.rawValue == "auto" }?.forbidden, true)
    }

    func testYamlRejectsAuto() throws {
        let yaml = """
        version: 1
        stages:
          - id: queue
            name: Queue
            kind: queue
            on_success: agent
          - id: agent
            name: Agent
            kind: agent
            agent: {harness: cursor-cli, model: auto, skill: test.md, permissions: write, mcp: [kaban]}
            on_success: done
          - id: done
            name: Done
            kind: terminal
        """
        let result = PipelineValidator.validate(yaml: yaml)
        XCTAssertTrue(result.errors.contains { $0.code == ValidationCode.modelAutoForbidden })
    }
}
