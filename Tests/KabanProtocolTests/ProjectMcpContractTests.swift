import Foundation
import XCTest
@testable import KabanProtocol

final class ProjectMcpContractTests: XCTestCase {
    func testLegacyAbsenceIsUnknownAndNewFactsSurviveSnapshotRoundtrip() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "snapshot.json", withExtension: nil, subdirectory: "Fixtures/legacy"))
        let decoder = KabanCoding.makeDecoder(), encoder = KabanCoding.makeEncoder()
        var snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: file))
        XCTAssertFalse(snapshot.projects.isEmpty); XCTAssertFalse(snapshot.pipelines.isEmpty)
        for project in snapshot.projects { XCTAssertNil(project.mcpAllowlist); XCTAssertNil(project.mcpIssue) }
        for stage in snapshot.pipelines.flatMap(\.stages) { XCTAssertNil(stage.mcp); XCTAssertNil(stage.effectiveMcp) }
        snapshot.projects[0].mcpAllowlist = ["kaban"]
        snapshot.projects[0].mcpIssue = .init(kind: .unexpected, name: "shared")
        snapshot.pipelines[0].stages[0].mcp = ["kaban", "disabled"]
        snapshot.pipelines[0].stages[0].effectiveMcp = ["kaban"]
        let received = try decoder.decode(Snapshot.self, from: encoder.encode(snapshot))
        XCTAssertEqual(received.projects[0].mcpAllowlist, ["kaban"])
        XCTAssertEqual(received.projects[0].mcpIssue, .init(kind: .unexpected, name: "shared"))
        XCTAssertEqual(received.pipelines[0].stages[0].mcp, ["kaban", "disabled"])
        XCTAssertEqual(received.pipelines[0].stages[0].effectiveMcp, ["kaban"])
    }
}
