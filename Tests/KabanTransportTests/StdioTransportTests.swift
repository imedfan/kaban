import Foundation
import XCTest
import KabanProtocol
import KabanTransport

final class StdioTransportTests: XCTestCase {
    func script(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.sh")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    func testUnresponsiveChildDeadlineAndCancellationReleasePipeReader() async throws {
        // No grandchildren; this fixture deliberately ignores TERM to exercise bounded cleanup.
        let executable = try script("trap '' TERM\nwhile :; do :; done\n")
        let transport = StdioDaemonTransport(executable: executable, database: "/not-used", timeout: 0.05)
        do { _ = try await transport.exchange(.init(.snapshot)); XCTFail("No deadline") }
        catch { XCTAssertEqual(error as? DaemonTransportError, .timedOut) }
        await transport.close()
        let cancellable = StdioDaemonTransport(executable: executable, database: "/not-used")
        let task = Task { try await cancellable.exchange(.init(.snapshot)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        await cancellable.close()
    }
    func testClosedTransportRejectsLateRequestsWithoutStartingAnotherChild() async throws {
        let response = DaemonResponse(.snapshot(Snapshot(seq: 0, projects: [], pipelines: [], tasks: [])))
        let json = String(decoding: try DaemonWire.encode(response), as: UTF8.self)
        let executable = try script("printf 'start\\n' >> \"$0.starts\"\nwhile IFS= read -r request; do printf '%s\\n' '" + json + "'; done\n")
        let marker = executable.appendingPathExtension("starts")
        let transport = StdioDaemonTransport(executable: executable, database: "/not-used")
        let first = try await transport.exchange(.init(.snapshot))
        XCTAssertEqual(first, response)
        await transport.close()
        for _ in 0..<3 {
            do { _ = try await transport.exchange(.init(.snapshot)); XCTFail("Closed transport restarted") }
            catch { XCTAssertEqual(error as? DaemonTransportError, .connectionLost) }
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "start\n")
        let replacement = StdioDaemonTransport(executable: executable, database: "/not-used")
        let next = try await replacement.exchange(.init(.snapshot))
        XCTAssertEqual(next, response)
        await replacement.close()
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "start\nstart\n")
    }

    func testCloseRejectsQueuedRequestAndTerminatesBusyChild() async throws {
        let executable = try script("printf 'start\\n' >> \"$0.starts\"\ntrap '' TERM\nwhile :; do :; done\n")
        let marker = executable.appendingPathExtension("starts")
        let transport = StdioDaemonTransport(executable: executable, database: "/not-used")
        let active = Task { try await transport.exchange(.init(.snapshot)) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let queued = Task { try await transport.exchange(.init(.snapshot)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await transport.close()
        for task in [active, queued] {
            do { _ = try await task.value; XCTFail("Request survived close") }
            catch { XCTAssertEqual(error as? DaemonTransportError, .connectionLost) }
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "start\n")
    }

    func testMalformedChildResponseIsNotRetriedAsACommand() async throws {
        let executable = try script("IFS= read -r request\nprintf 'invalid JSON\\n'\n")
        let transport = StdioDaemonTransport(executable: executable, database: "/not-used")
        do { _ = try await DaemonClient(transport: transport).send(.init(command: .pauseAll)); XCTFail("Malformed reply accepted") }
        catch { XCTAssertEqual(error as? DaemonTransportError, .invalidReply) }
        await transport.close()
    }
}
