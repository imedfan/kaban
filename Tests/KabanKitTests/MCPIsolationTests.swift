import XCTest
import KabanProtocol
@testable import KabanKit

final class MCPIsolationTests: XCTestCase {
    private let board = "http://127.0.0.1:9/mcp"

    func testDisabledServerWarnsAndDoesNotApproveEverything() throws {
        let decision = MCPPreflight.decide(
            stageServers: ["kaban", "github"],
            allowlist: [],
            definitions: [MCPServerDefinition(name: "github", source: "project", endpoint: "npx")],
            boardURL: board,
            listOutput: "kaban\tboard\n",
            listExit: 0)
        XCTAssertNil(decision.block)
        XCTAssertEqual(decision.warnings, ["mcp_not_allowlisted:github"])
        XCTAssertEqual(try names(decision.configJSON), ["kaban"])
        XCTAssertTrue(decision.configJSON.contains(MCPPreflight.tokenReference))
        XCTAssertFalse(decision.configJSON.contains("--approve-mcps"))
        XCTAssertFalse(decision.configJSON.contains("raw-token"))
        let plan = try CursorLaunch.plan(model: "composer-2", readOnly: true, resumeRequested: false, verifiedSessionId: nil, prompt: "x", environment: [:])
        XCTAssertFalse(plan.arguments.contains("--approve-mcps"))
    }

    func testUnexpectedAndUnresolvableListsBlockTheRun() throws {
        let unexpected = MCPPreflight.decide(stageServers: ["kaban"], allowlist: [], definitions: [], boardURL: board, listOutput: "kaban\tboard\nother\tparent\n", listExit: 0)
        XCTAssertEqual(unexpected.block, .unexpected("other"))
        XCTAssertEqual(try names(unexpected.configJSON), ["kaban"])
        let broken = MCPPreflight.decide(stageServers: ["kaban"], allowlist: [], definitions: [], boardURL: board, listOutput: "not a list", listExit: 0)
        XCTAssertEqual(broken.block, .unresolvable("mcp list"))
        let failed = MCPPreflight.decide(stageServers: ["kaban"], allowlist: ["github"], definitions: [], boardURL: board, listOutput: "kaban\tboard\n", listExit: 1)
        XCTAssertEqual(failed.block, .unresolvable("mcp list"))
        let collision = MCPPreflight.decide(
            stageServers: ["kaban", "github"],
            allowlist: ["github"],
            definitions: [
                MCPServerDefinition(name: "github", source: "project", endpoint: "https://a.example"),
                MCPServerDefinition(name: "github", source: "personal", endpoint: "https://b.example"),
            ],
            boardURL: board,
            listOutput: "kaban\tboard\ngithub\tproject\n",
            listExit: 0)
        XCTAssertEqual(collision.block, .unresolvable("github"))
        XCTAssertEqual(try names(collision.configJSON), ["kaban"])
    }

    func testSwappedFileDoesNotRemainInTheDiff() throws {
        let root = try gitRepo()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        let original = "{\"mcpServers\":{\"local\":{\"command\":\"echo\"}}}\n"
        try Data(original.utf8).write(to: root.appendingPathComponent(".cursor/mcp.json"))
        _ = try git(["add", ".cursor/mcp.json"], root)
        _ = try git(["commit", "-m", "config"], root)
        let generated = "{\"mcpServers\":{\"kaban\":{\"url\":\"\(board)\",\"headers\":{\"Authorization\":\"Bearer ${env:KABAN_RUN_TOKEN}\"}}}}"
        let installed = try MCPConfigFile.install(cloneRoot: root, generated: generated)
        XCTAssertFalse(try git(["diff", "--", ".cursor/mcp.json"], root).isEmpty)
        try MCPConfigFile.restore(cloneRoot: root, installed: installed)
        XCTAssertEqual(try git(["diff", "--", ".cursor/mcp.json"], root), "")
        XCTAssertEqual(try git(["status", "--porcelain"], root), "")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".cursor/mcp.json"), encoding: .utf8), original)
    }

    func testGeneratedFileIsNotLeftBehind() throws {
        let root = try gitRepo()
        let installed = try MCPConfigFile.install(cloneRoot: root, generated: "{\"mcpServers\":{\"kaban\":{\"url\":\"\(board)\"}}}")
        XCTAssertTrue(installed.excludeAdded)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8).contains(".cursor/mcp.json"))
        XCTAssertEqual(try git(["status", "--porcelain"], root), "")
        try MCPConfigFile.restore(cloneRoot: root, installed: installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".cursor/mcp.json").path))
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8).contains(".cursor/mcp.json"))
    }

    func testSymlinkIsNotFollowed() throws {
        let root = try gitRepo()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".cursor"), withDestinationURL: outside)
        XCTAssertThrowsError(try MCPConfigFile.install(cloneRoot: root, generated: "{}")) { error in
            XCTAssertEqual(error as? MCPConfigError, .symlink)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("mcp.json").path))
    }

    func testDirectGitAndDirectWritesAreDenied() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("sandbox-exec is not on this host")
        }
        let unresolved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: unresolved) }
        let root = URL(fileURLWithPath: physical(unresolved.path))
        let clone = root.appendingPathComponent("clone")
        let scratch = root.appendingPathComponent("scratch")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try git(["init"], clone)
        _ = try git(["config", "user.email", "probe@example.com"], clone)
        _ = try git(["config", "user.name", "Probe"], clone)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        let config = clone.appendingPathComponent(".git/config")
        let pipeline = clone.appendingPathComponent(".kaban/pipeline.yaml")
        let before = try Data(contentsOf: config)
        try Data("marker\n".utf8).write(to: pipeline)
        let profile = root.appendingPathComponent("tool.sb")
        try SeatbeltProfile.tool.write(to: profile, atomically: true, encoding: .utf8)
        let deniedGit = sandbox(profile: profile, clone: clone, scratch: scratch, home: home, ["/usr/bin/git", "-C", clone.path, "config", "user.email", "other@example.com"])
        XCTAssertNotEqual(deniedGit.status, 0, deniedGit.error)
        XCTAssertEqual(try Data(contentsOf: config), before)
        let deniedWrite = sandbox(profile: profile, clone: clone, scratch: scratch, home: home, ["/bin/sh", "-c", "printf x > \"$1\"", "sh", pipeline.path])
        XCTAssertNotEqual(deniedWrite.status, 0, deniedWrite.error)
        XCTAssertEqual(try String(contentsOf: pipeline, encoding: .utf8), "marker\n")
        let outside = root.appendingPathComponent("forbidden")
        let deniedOutside = sandbox(profile: profile, clone: clone, scratch: scratch, home: home, ["/usr/bin/touch", outside.path])
        XCTAssertNotEqual(deniedOutside.status, 0, deniedOutside.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        let allowed = sandbox(profile: profile, clone: clone, scratch: scratch, home: home, ["/usr/bin/touch", clone.appendingPathComponent("allowed").path])
        XCTAssertEqual(allowed.status, 0, allowed.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.appendingPathComponent("allowed").path))
        let openGit = process(["/usr/bin/git", "-C", clone.path, "config", "user.email", "other@example.com"])
        XCTAssertEqual(openGit.status, 0, openGit.error)
        XCTAssertNotEqual(try Data(contentsOf: config), before)
    }

    private func physical(_ path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/pwd")
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.arguments = ["-P"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return path }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        return text.isEmpty ? path : text
    }

    private func names(_ json: String) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let servers = object?["mcpServers"] as? [String: Any]
        return (servers?.keys.sorted()) ?? []
    }

    private func gitRepo() throws -> URL {
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
        let result = process(["/usr/bin/git", "-C", root.path] + arguments)
        XCTAssertEqual(result.status, 0, result.error)
        return result.output
    }

    private func sandbox(profile: URL, clone: URL, scratch: URL, home: URL, _ command: [String]) -> (status: Int32, error: String) {
        let result = process(["/usr/bin/sandbox-exec"] + SeatbeltProfile.arguments(profile: profile.path, clone: clone.path, scratch: scratch.path, fakeHome: home.path, mcpPort: "43191", proxyPort: "43192", command: command))
        return (result.status, result.error)
    }

    private func process(_ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch {
            return (1, "", String(describing: error))
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
