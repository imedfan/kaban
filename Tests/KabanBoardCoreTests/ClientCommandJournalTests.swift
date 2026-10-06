import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class ClientCommandJournalTests: XCTestCase {
    @MainActor func testLostReplySurvivesReopenAndUsesTheExactEnvelope() throws {
        let storage = MemoryKeyValueStore()
        let journal = try ClientCommandJournal(storage: storage, key: "developer")
        let envelope = CommandEnvelope(command: .createTask(projectId: "shop", title: "  Заголовок  ", body: "## Body\r\n\n`exact`  "))
        try journal.begin(envelope, at: Fix.t0)
        try journal.markUncertain(envelope.commandId)
        let reopened = try ClientCommandJournal(storage: storage, key: "developer")
        let record = try XCTUnwrap(reopened.records.first)
        XCTAssertEqual(record.envelope, envelope)
        XCTAssertTrue(record.isPending)
        XCTAssertTrue(record.deliveryUncertain)
        try reopened.begin(envelope)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertThrowsError(try reopened.begin(.init(commandId: envelope.commandId, command: .pauseAll)))
        XCTAssertEqual(try ClientCommandJournal(storage: storage, key: "installed").records, [])
    }
    @MainActor func testAcknowledgementKeepsPendingAndAnEarlierEventKeepsItsMetadata() throws {
        let journal = try ClientCommandJournal(storage: MemoryKeyValueStore(), key: "commands")
        let envelope = CommandEnvelope(command: .pauseTask(taskId: "t-1"))
        try journal.begin(envelope)
        let reply = CommandReply(commandId: envelope.commandId, seq: 8, result: .ok)
        try journal.receive(reply)
        XCTAssertTrue(journal.records[0].isPending, "An acknowledgement is not an applied event")
        try journal.observe(Fix.envelope(7, .taskUpdated(Fix.card("t-1", state: .paused)), commandId: UUID()))
        XCTAssertTrue(journal.records[0].isPending)
        try journal.observe(Fix.envelope(8, .taskUpdated(Fix.card("t-1", state: .paused)), commandId: envelope.commandId))
        XCTAssertFalse(journal.records[0].isPending)
        XCTAssertEqual(journal.records[0].reply, reply)

        let create = CommandEnvelope(command: .createTask(projectId: "shop", title: "Task", body: ""))
        try journal.begin(create)
        try journal.observe(Fix.envelope(9, .taskCreated(Fix.card("t-2")), commandId: create.commandId))
        try journal.receive(.init(commandId: create.commandId, seq: 9, result: .taskCreated("t-2")))
        XCTAssertFalse(journal.records[1].isPending)
        XCTAssertEqual(journal.records[1].eventSeq, 9)
    }
    @MainActor func testRejectionAndCorruptStorageDoNotSilentlyLoseTheRequest() throws {
        let storage = MemoryKeyValueStore()
        let journal = try ClientCommandJournal(storage: storage, key: "commands")
        let envelope = CommandEnvelope(command: .cancelTask(taskId: "t-1", keepBranch: true))
        try journal.begin(envelope)
        try journal.receive(.init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "invalid_state", message: "Changed"))))
        XCTAssertFalse(journal.records[0].isPending)
        XCTAssertEqual(journal.records[0].envelope, envelope)
        storage.set(Data("invalid".utf8), forKey: "commands")
        XCTAssertThrowsError(try ClientCommandJournal(storage: storage, key: "commands"))
        XCTAssertEqual(storage.data(forKey: "commands"), Data("invalid".utf8))
    }
    @MainActor func testMockPreservesReceiptAndPublishesCapabilitiesHonestly() async throws {
        let client: any KabanClient = MockKabanClient()
        let envelope = CommandEnvelope(command: .createTask(projectId: "shop", title: "Once", body: "## Exact\n"))
        let first = try await client.send(envelope)
        let second = try await client.send(envelope)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.commandId, envelope.commandId)
        XCTAssertNotNil(first.seq)
        let snapshot = try await client.getSnapshot()
        XCTAssertEqual(snapshot.tasks.filter { $0.title == "Once" }.count, 1)
        let capabilities = try await client.capabilities()
        XCTAssertTrue(capabilities.supports(.createTask))
        XCTAssertFalse(capabilities.supports(.restoreWIP))
        XCTAssertFalse(capabilities.supportsOperation("readLog"))
        do { _ = try await client.readLog(runId: "none", fromOffset: 0, limit: 1); XCTFail("Fake log") }
        catch { XCTAssertEqual((error as? CommandError)?.code, CommandError.unsupportedOperationCode) }
    }
    func testIncompleteAndFakeCapabilitiesCannotEnableTheProductionSession() throws {
        var capabilities = DaemonCapabilities(operations: ["snapshot", "command", "subscribe", "synchronize", "ephemeral"].map { .init(name: $0, supported: true) },
                                              commands: [.init(name: "createTask", support: .managedFakeOnly)])
        XCTAssertNoThrow(try capabilities.requireSession())
        XCTAssertFalse(capabilities.supports(.createTask))
        capabilities.operations.removeLast()
        XCTAssertThrowsError(try capabilities.requireSession())
    }
}
