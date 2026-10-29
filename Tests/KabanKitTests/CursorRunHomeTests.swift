import Foundation
import XCTest
@testable import KabanKit

final class CursorRunHomeTests: XCTestCase {
    func testRunHomePreservesKeychainDiscoveryWithoutCopyingPersonalMCP() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-home-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user")
        let run = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: user.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try "personal-server".write(to: user.appendingPathComponent(".cursor/mcp.json"), atomically: true, encoding: .utf8)
        try CursorRunHome.prepare(run, userHome: user)
        try CursorRunHome.prepare(run, userHome: user)
        #if os(macOS)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: run.appendingPathComponent("Library/Keychains").path), user.appendingPathComponent("Library/Keychains").path)
        #endif
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent(".cursor/mcp.json").path))
        XCTAssertEqual(try String(contentsOf: user.appendingPathComponent(".cursor/mcp.json"), encoding: .utf8), "personal-server")
    }

    func testApprovalAndPermissionsProduceExactReadOnlyAndWriteArguments() throws {
        let read = try CursorLaunch.plan(model: "review-model", readOnly: true, resumeRequested: true, verifiedSessionId: nil,
            prompt: "review this", environment: [:], mcpPreflightPassed: true)
        XCTAssertEqual(read.arguments, ["-p", "--output-format", "stream-json", "--model", "review-model", "--trust", "--approve-mcps", "review this"])
        let write = try CursorLaunch.plan(model: "write-model", readOnly: false, resumeRequested: false, verifiedSessionId: nil,
            prompt: "implement this", environment: [:], mcpPreflightPassed: true)
        XCTAssertEqual(write.arguments, ["-p", "--output-format", "stream-json", "--model", "write-model", "--trust", "--approve-mcps", "--force", "implement this"])
    }
}
