import XCTest
import KabanProtocol
@testable import KabanKit

final class StageCommandTests: XCTestCase {
    func testCommandCapturesOutputAndATimeoutDoesNotWaitForTheChild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let ok = try StageCommand.run(command: "printf hello", cwd: root.path, environment: StageCommand.environment(), timeout: 2)
        XCTAssertEqual(ok.status, 0)
        XCTAssertEqual(ok.output, "hello")
        XCTAssertFalse(ok.timedOut)
        let started = Date()
        let slow = try StageCommand.run(command: "/bin/sleep 30", cwd: root.path, environment: StageCommand.environment(), timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(slow.timedOut)
        XCTAssertEqual(slow.status, 124)
    }

    func testASecondCommitWithTheSameMarkerIsTheSameCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try git(root, ["init", "-b", "main"])
        try git(root, ["config", "user.name", "Stage"])
        try git(root, ["config", "user.email", "stage@example.test"])
        try "base".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try git(root, ["add", "."])
        try git(root, ["commit", "-m", "base"])
        let planted = root.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nprintf planted >> \"$GIT_DIR/../planted\"\n".write(to: planted, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: planted.path)
        try "note".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let identity = GitIdentity(name: "Stage", email: "stage@example.test")
        let marker = TaskClone.effectMarkerPrefix + "task/1/commit"
        let first = try TaskClone.commitMarked(clone: root.path, message: "kaban: dev task", marker: marker, identity: identity)
        let second = try TaskClone.commitMarked(clone: root.path, message: "kaban: dev task", marker: marker, identity: identity)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try subjects(root).filter { $0.contains("kaban: dev task") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("planted").path))
        try "again".write(to: root.appendingPathComponent("again.txt"), atomically: true, encoding: .utf8)
        let third = try TaskClone.commitMarked(clone: root.path, message: "other", marker: marker, identity: identity)
        XCTAssertEqual(third, first)
        XCTAssertFalse(try subjects(root).contains("other"))
    }

    private func git(_ repo: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.environment = DaemonGit.processEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(args)")
    }

    private func subjects(_ repo: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "log", "--format=%s"]
        process.environment = DaemonGit.processEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
