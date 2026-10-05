import Foundation
import XCTest
import KabanKit
import KabanProtocol
import KabanBoardCore
@testable import KabanDaemonCore
@testable import KabanTransport

final class DaemonTransportTests: XCTestCase {
    func fixture() throws -> KabanStore { try makeDaemonTransportFixture(on: self) }
    func testSnapshotSubscribeHandshakeAndPartialPagesMatchAuthoritativeProjection() async throws {
        let store = try fixture()
        // Use the same store as the subscriber; another client can commit between snapshot and subscribe.
        let subscriber = DaemonClient(transport: LocalTransport(service: .init(store: store)))
        let snapshot = try await subscriber.getSnapshot()
        var board = BoardProjection(snapshot: snapshot)
        let envelope = CommandEnvelope(command: .createTask(projectId: "p", title: "Unicode 🐗", body: "Markdown **body**\n"))
        let reply = try store.execute(envelope)
        var cursor = snapshot.seq
        repeat {
            let page = try await subscriber.subscribe(fromSeq: cursor, limit: 1)
            XCTAssertFalse(page.resyncRequired)
            for event in page.events { XCTAssertEqual(board.apply(event), .applied); cursor = event.seq }
            if cursor == page.latestSeq { break }
        } while true
        XCTAssertEqual(cursor, reply.seq)
        let authoritative = try await subscriber.getSnapshot()
        XCTAssertEqual(board.tasks.values.sorted { $0.id.rawValue < $1.id.rawValue }, authoritative.tasks)
        if case .taskCreated(let id) = reply.result {
            let detail = try await subscriber.send(.init(command: .getTaskDetail(taskId: id)))
            guard case .taskDetail(let value) = detail.result else { return XCTFail("Missing detail") }
            XCTAssertEqual(value.body, "Markdown **body**\n")
        } else { XCTFail("Missing task id") }
    }
    func testLostReplyRetriesOriginalEnvelopeExactlyOnce() async throws {
        let store = try fixture(), transport = LostReplyTransport(service: .init(store: store))
        let client = DaemonClient(transport: transport)
        let request = CommandEnvelope(command: .createTask(projectId: "p", title: "Created once", body: "Text"))
        let reply = try await client.send(request)
        let again = try await client.send(request)
        XCTAssertEqual(reply, again)
        let snapshot = try await client.getSnapshot()
        XCTAssertEqual(snapshot.tasks.count, 1)
        let requests = await transport.commands
        XCTAssertEqual(requests, [request, request, request])
        XCTAssertEqual(try store.getSnapshot().tasks.count, 1)
        let conflict = try await client.send(.init(commandId: request.commandId, command: .createTask(projectId: "p", title: "Other", body: "Text")))
        guard case .error(let error) = conflict.result else { return XCTFail("Conflict accepted") }
        XCTAssertEqual(error.code, "command_id_conflict")
    }
    func testRetentionIncludingEmptyJournalPreservesSequenceAndRequiresResync() throws {
        let store = try fixture(), before = try store.getSnapshot()
        try store.database.write { db in try db.execute(sql: "DELETE FROM event") }
        XCTAssertEqual(try store.getSnapshot().seq, before.seq)
        XCTAssertTrue(try store.journalPage(after: 0).resyncRequired)
        XCTAssertFalse(try store.journalPage(after: before.seq).resyncRequired)
        XCTAssertTrue(try store.journalPage(after: before.seq + 1).resyncRequired)
        let reply = try store.execute(.init(command: .pauseAll))
        XCTAssertEqual(reply.seq, before.seq + 1)
        XCTAssertEqual(try store.journalPage(after: before.seq).events.count, 1)
        try store.database.write { db in try db.execute(sql: "DELETE FROM event WHERE seq = ?", arguments: [reply.seq]) }
        XCTAssertTrue(try store.journalPage(after: before.seq).resyncRequired)
    }
    func testInvalidVersionCursorAndMalformedPayloadDoNotMutateStore() throws {
        let store = try fixture(), service = DaemonService(store: store)
        var request = DaemonRequest(.command(.init(command: .pauseAll))); request.protocolVersion = 99
        guard case .error(let mismatch) = service.handle(request).result else { return XCTFail("Version accepted") }
        XCTAssertEqual(mismatch.code, CommandError.protocolMismatchCode)
        for operation in [DaemonRequest.Operation.subscribe(fromSeq: -1, limit: 2), .subscribe(fromSeq: 0, limit: 0), .subscribe(fromSeq: 0, limit: 257)] {
            guard case .error(let error) = service.handle(.init(operation)).result else { return XCTFail("Invalid subscription accepted") }
            XCTAssertEqual(error.code, "invalid_request")
        }
        let response = try DaemonWire.decode(DaemonResponse.self, from: service.handle(data: Data("not json".utf8)))
        guard case .error(let invalid) = response.result else { return XCTFail("Malformed request accepted") }
        XCTAssertEqual(invalid.code, "invalid_request")
        XCTAssertEqual(try store.getSnapshot().seq, 2)
    }
    func testWatchRetentionReplacesSnapshotBeforeNewEvents() async throws {
        let store = try fixture()
        let client = DaemonClient(transport: LocalTransport(service: .init(store: store)))
        // An expired cursor is replaced, rather than skipped to the newest sequence.
        try await store.database.write { db in try db.execute(sql: "DELETE FROM event") }
        let stream = client.updates(after: 0)
        var iterator = stream.makeAsyncIterator()
        guard case .snapshot(let snapshot) = try await iterator.next() else { return XCTFail("Missing resync snapshot") }
        XCTAssertEqual(snapshot.seq, 2)
        let reply = try store.execute(.init(command: .pauseAll))
        guard case .event(let event) = try await iterator.next() else { return XCTFail("Missing live event") }
        XCTAssertEqual(event.seq, reply.seq)
    }
    func testWatchReconnectRetainsLastAppliedCursor() async throws {
        let store = try fixture(), seq = try store.getSnapshot().seq
        let reply = try store.execute(.init(command: .pauseAll))
        let transport = LostSubscriptionTransport(service: .init(store: store))
        let stream = DaemonClient(transport: transport).updates(after: seq)
        var iterator = stream.makeAsyncIterator()
        guard case .event(let event) = try await iterator.next() else { return XCTFail("No event after reconnect") }
        XCTAssertEqual(event.seq, reply.seq)
        let cursors = await transport.cursors
        XCTAssertEqual(cursors.prefix(2), [seq, seq])
    }
    func testSlowSubscriberFailsExplicitlyWithoutSilentlySkippingEvents() async throws {
        let stream = DaemonClient(transport: EndlessJournalTransport()).updates(after: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        var delivered: Seq = 0
        do {
            for try await update in stream {
                guard case .event(let event) = update else { return XCTFail("Unexpected snapshot") }
                XCTAssertEqual(event.seq, delivered + 1); delivered = event.seq
            }
            XCTFail("Overflow went unnoticed")
        } catch { XCTAssertEqual(error as? DaemonTransportError, .bufferOverflow) }
        XCTAssertGreaterThan(delivered, 0)
    }
    func testWireRoundTripAndPayloadLimit() throws {
        let store = try fixture(), snapshot = try store.getSnapshot()
        let response = DaemonResponse(.snapshot(snapshot))
        XCTAssertEqual(try DaemonWire.decode(DaemonResponse.self, from: DaemonWire.encode(response)), response)
        XCTAssertThrowsError(try DaemonWire.decode(DaemonRequest.self, from: Data(repeating: 0, count: DaemonWire.maxMessageBytes + 1)))
    }
}

private actor LostSubscriptionTransport: DaemonTransport {
    let service: DaemonService
    var cursors: [Seq] = []
    init(service: DaemonService) { self.service = service }
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        if case .subscribe(let seq, _) = request.operation {
            cursors.append(seq)
            if cursors.count == 1 { throw DaemonTransportError.connectionLost }
        }
        return service.handle(request)
    }
}
private struct EndlessJournalTransport: DaemonTransport {
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        guard case .subscribe(let seq, let limit) = request.operation else { throw DaemonTransportError.invalidReply }
        let events = (1...limit).map { i in EventEnvelope(seq: seq + Seq(i), at: Date(timeIntervalSince1970: 0), projectId: nil, event: .unknown(type: "future")) }
        return .init(.events(.init(fromSeq: seq, latestSeq: 10_000, events: events)))
    }
}

private struct LocalTransport: DaemonTransport {
    let service: DaemonService
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        // Exercise exactly the codec that crosses the process boundary.
        try DaemonWire.decode(DaemonResponse.self, from: service.handle(data: DaemonWire.encode(request)))
    }
}
private actor LostReplyTransport: DaemonTransport {
    let service: DaemonService
    var commands: [CommandEnvelope] = []
    init(service: DaemonService) { self.service = service }
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        let response = service.handle(request)
        if case .command(let envelope) = request.operation {
            commands.append(envelope)
            if commands.count == 1 { throw DaemonTransportError.connectionLost }
        }
        return response
    }
}

func makeDaemonTransportFixture(on testCase: XCTestCase) throws -> KabanStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try KabanStore(path: root.appendingPathComponent("db.sqlite").path)
    let pipeline = try XCTUnwrap(PipelineValidator.validate(yaml: """
    version: 1
    stages:
      - {id: queue, name: Queue, kind: queue, on_success: agent}
      - id: agent
        name: Agent
        kind: agent
        agent: {harness: cursor-cli, model: fake, skill: test.md, permissions: write, mcp: [kaban]}
        on_success: review
      - {id: review, name: Review, kind: human, on_success: done}
      - {id: done, name: Done, kind: terminal}
    """).config)
    _ = try store.registerProject(.init(id: "p", name: "P", path: "/not-read", mascotSeed: "p"), pipeline: pipeline, commandId: UUID(), at: Date())
    return store
}
