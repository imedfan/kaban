#if os(macOS)
import Foundation
import XCTest
import XPC
import KabanProtocol
import KabanDaemonCore
@testable import KabanTransport

@available(macOS 26.0, *)
final class XPCTransportTests: XCTestCase {
    func testActualXPCCodecCommandCorrelationAndSnapshot() async throws {
        let store = try KabanStore(path: ":memory:")
        let service = DaemonService(store: store)
        let listener = XPCListener(options: .inactive) { request in request.accept { (data: Data) in service.handle(data: data) } }
        try listener.activate()
        defer { listener.cancel() }
        let transport = XPCDaemonTransport(endpoint: listener.endpoint)
        let client = DaemonClient(transport: transport)
        let snapshot = try await client.getSnapshot()
        XCTAssertEqual(snapshot.seq, 0)
        let envelope = CommandEnvelope(command: .pauseAll)
        let reply = try await client.send(envelope)
        XCTAssertEqual(reply.commandId, envelope.commandId)
        XCTAssertEqual(reply.result, .ok)
        let page = try await client.subscribe(fromSeq: 0)
        XCTAssertEqual(page.events.first?.commandId, envelope.commandId)
        let repeated = try await client.send(envelope)
        XCTAssertEqual(repeated, reply)
        let replacement = try await client.synchronize()
        XCTAssertEqual(replacement.snapshot.seq, reply.seq)
        try service.publishEphemeral(.runnerChecked(.init(ok: true, version: "fixture", checkedAt: Date())))
        let live = try await client.ephemeral(after: replacement.cursor)
        XCTAssertEqual(live.events.count, 1)
        XCTAssertEqual(live.events.first?.afterSeq, reply.seq)
        let capabilities = try await client.capabilities()
        XCTAssertEqual(capabilities, DaemonService.capabilities)
        await transport.close()
    }
    func testUnansweredXPCRequestTimesOutAndTaskCancellationFinishes() async throws {
        let response = try DaemonWire.encode(DaemonResponse(.snapshot(Snapshot(seq: 0, projects: [], pipelines: [], tasks: []))))
        let listener = XPCListener(options: .inactive) { request in request.accept { (_: Data) -> Data in
            Thread.sleep(forTimeInterval: 0.2)
            return response
        } }
        try listener.activate()
        defer { listener.cancel() }
        let transport = XPCDaemonTransport(endpoint: listener.endpoint, timeout: 0.05)
        do { _ = try await transport.exchange(.init(.snapshot)); XCTFail("No timeout") }
        catch { XCTAssertEqual(error as? DaemonTransportError, .timedOut) }
        let cancellable = XPCDaemonTransport(endpoint: listener.endpoint, timeout: 10)
        let task = Task { try await cancellable.exchange(.init(.snapshot)) }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        await cancellable.close()
    }
}
#endif
