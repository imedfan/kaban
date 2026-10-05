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
    func testMalformedChildResponseIsNotRetriedAsACommand() async throws {
        let executable = try script("IFS= read -r request\nprintf 'invalid JSON\\n'\n")
        let transport = StdioDaemonTransport(executable: executable, database: "/not-used")
        do { _ = try await DaemonClient(transport: transport).send(.init(command: .pauseAll)); XCTFail("Malformed reply accepted") }
        catch { XCTAssertEqual(error as? DaemonTransportError, .invalidReply) }
        await transport.close()
    }
}
