import XCTest
@testable import KabanKit

final class ProcessGroupTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClassifierSplitsExitZeroSilenceAndALateExit() {
        XCTAssertEqual(ProcessExitClassifier.classify(exitCode: 0, runStillActive: true, producedActivity: true, changedFiles: false), .noFinalCall)
        XCTAssertEqual(ProcessExitClassifier.classify(exitCode: 0, runStillActive: true, producedActivity: false, changedFiles: true), .noFinalCall)
        XCTAssertEqual(ProcessExitClassifier.classify(exitCode: 0, runStillActive: true, producedActivity: false, changedFiles: false), .silentDeferred)
        XCTAssertEqual(ProcessExitClassifier.classify(exitCode: 0, runStillActive: false, producedActivity: true, changedFiles: true), .inactive)
        XCTAssertEqual(ProcessExitClassifier.classify(exitCode: 9, runStillActive: true, producedActivity: true, changedFiles: false), .crash(9))
        let now = Date()
        let started = Date()
        XCTAssertNil(ProcessDeadlines(stall: now.addingTimeInterval(3600), wall: now.addingTimeInterval(7200)).due(at: now))
        XCTAssertEqual(ProcessDeadlines(stall: now.addingTimeInterval(-1), wall: now.addingTimeInterval(10)).due(at: now), .stall)
        XCTAssertEqual(ProcessDeadlines(stall: now.addingTimeInterval(10), wall: now.addingTimeInterval(-1)).due(at: now), .wall)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testStopKillsOnlyTheRecordedGroupAndDoesNotWait() throws {
        let first = try spawn(sleep: "30", name: "a")
        let second = try spawn(sleep: "30", name: "b")
        defer { stop(first); stop(second) }
        XCTAssertNotEqual(first.processGroup, second.processGroup)
        XCTAssertEqual(ProcessGroup.processGroup(of: first.pid), first.processGroup)
        let started = Date()
        XCTAssertNil(ProcessGroup.poll(first.pid))
        XCTAssertThrowsError(try ProcessGroup.stop(pid: first.pid, processGroup: second.processGroup, birth: first.birth)) {
            XCTAssertEqual($0 as? ProcessGroup.Failure, .foreignGroup)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(ProcessGroup.isAlive(first.pid))
        XCTAssertTrue(ProcessGroup.isAlive(second.pid))
        XCTAssertEqual(try ProcessGroup.stop(pid: first.pid, processGroup: first.processGroup, birth: first.birth), .signaled)
        let reapDeadline = Date().addingTimeInterval(2)
        var reaped: Int32?
        while Date() < reapDeadline && reaped == nil {
            reaped = ProcessGroup.poll(first.pid)
            if reaped == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertNotNil(reaped)
        XCTAssertEqual(try ProcessGroup.stop(pid: first.pid, processGroup: first.processGroup, birth: first.birth), .alreadyGone)
        XCTAssertTrue(ProcessGroup.isAlive(second.pid))
        XCTAssertFalse(ProcessGroup.isAlive(first.pid))
    }

    func testDescendantsDieWithTheGroup() throws {
        let script = root.appendingPathComponent("child.py")
        try """
        import os, time
        pid = os.fork()
        if pid == 0:
            open("child.pid", "w").write(str(os.getpid()))
            time.sleep(30)
            raise SystemExit(0)
        time.sleep(30)
        """.write(to: script, atomically: true, encoding: .utf8)
        let leader = try ProcessGroup.spawn(executable: "/usr/bin/python3", arguments: [script.path], workingDirectory: root.path, environment: ProcessInfo.processInfo.environment, standardOutput: root.appendingPathComponent("out").path, standardError: root.appendingPathComponent("err").path)
        defer { stop(leader) }
        let child = try waitForChild()
        XCTAssertEqual(ProcessGroup.processGroup(of: child), leader.processGroup)
        let started = Date()
        XCTAssertEqual(try ProcessGroup.stop(pid: leader.pid, processGroup: leader.processGroup, birth: leader.birth), .signaled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        _ = ProcessGroup.poll(leader.pid)
        try waitUntilIdle(leader.pid)
        try waitUntilIdle(child)
        XCTAssertFalse(isRunning(leader.pid))
        XCTAssertFalse(isRunning(child))
    }

    func spawn(sleep seconds: String, name: String) throws -> ProcessGroup.Handle {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ProcessGroup.spawn(executable: "/bin/sleep", arguments: [seconds], workingDirectory: directory.path, environment: ["PATH": "/bin:/usr/bin"], standardOutput: directory.appendingPathComponent("out").path, standardError: directory.appendingPathComponent("err").path)
    }

    func stop(_ handle: ProcessGroup.Handle) {
        _ = try? ProcessGroup.stop(pid: handle.pid, processGroup: handle.processGroup, birth: handle.birth)
        _ = ProcessGroup.poll(handle.pid)
    }

    func waitForChild() throws -> Int32 {
        let deadline = Date().addingTimeInterval(2)
        let url = root.appendingPathComponent("child.pid")
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("child pid was not written")
        return 0
    }

    func waitUntilIdle(_ pid: Int32) throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline && isRunning(pid) { Thread.sleep(forTimeInterval: 0.02) }
    }

    func isRunning(_ pid: Int32) -> Bool {
        let state = processState(pid)
        return state.hasPrefix("S") || state.hasPrefix("R") || state.hasPrefix("U") || state.hasPrefix("D") || state.hasPrefix("I")
    }

    func processState(_ pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "state=", "-p", String(pid)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
