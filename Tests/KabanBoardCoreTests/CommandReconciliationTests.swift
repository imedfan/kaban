import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class CommandReconciliationTests: XCTestCase {
    @MainActor func testUnrelatedCorrelationCannotResolveAnotherResourceOrEventType() async throws {
        let journal = try ClientCommandJournal(storage: MemoryKeyValueStore(), key: "commands")
        let envelope = CommandEnvelope(command: .editTask(taskId: "t-1", title: "Exact", body: nil))
        try journal.begin(envelope)
        try journal.receive(.init(commandId: envelope.commandId, seq: 4, result: .ok))
        try journal.observe(Fix.envelope(2, .taskEdited(Fix.card("other")), commandId: envelope.commandId))
        try journal.observe(Fix.envelope(3, .taskUpdated(Fix.card("t-1")), commandId: envelope.commandId))
        XCTAssertEqual(journal.records[0].phase, .awaitingEvent)
        try journal.observe(Fix.envelope(4, .taskEdited(Fix.card("t-1", title: "Exact")), commandId: envelope.commandId))
        XCTAssertEqual(journal.records[0].phase, .applied)
        XCTAssertEqual(journal.records[0].confirmedSeq, 4)
        try journal.markUncertain(envelope.commandId)
        XCTAssertEqual(journal.records[0].phase, .applied, "A late transport error cannot undo observed application")
    }

    @MainActor func testRetentionReceiptNeedsAProjectionCoveringItsSeq() async throws {
        let storage = MemoryKeyValueStore()
        let envelope = CommandEnvelope(command: .approve(taskId: "review"))
        let journal = try ClientCommandJournal(storage: storage, key: "commands")
        try journal.begin(envelope)
        try journal.markUncertain(envelope.commandId)
        let reopened = try ClientCommandJournal(storage: storage, key: "commands")
        XCTAssertEqual(reopened.records[0].phase, .deliveryUncertain)
        XCTAssertEqual(reopened.records[0].envelope, envelope)
        try reopened.confirmThrough(snapshotSeq: 500)
        XCTAssertTrue(reopened.records[0].isPending, "No event or receipt means unknown, regardless of snapshot seq")
        try reopened.receive(.init(commandId: envelope.commandId, seq: 501, result: .ok))
        try reopened.confirmThrough(snapshotSeq: 500)
        XCTAssertEqual(reopened.records[0].phase, .awaitingEvent)
        try reopened.confirmThrough(snapshotSeq: 502)
        XCTAssertEqual(reopened.records[0].phase, .applied)
        XCTAssertEqual(reopened.records[0].coveredSnapshotSeq, 502)
        XCTAssertEqual(try ClientCommandJournal(storage: storage, key: "commands").records, reopened.records)
    }

    @MainActor func testRestoreReceiptAndTaskCardNeverPretendTheGitEffectCompleted() async throws {
        let journal = try ClientCommandJournal(storage: MemoryKeyValueStore(), key: "commands")
        let envelope = CommandEnvelope(command: .restoreWIP(taskId: "t-1", runId: "r-1", wipRef: "refs/kaban/wip/r-1"))
        try journal.begin(envelope)
        try journal.receive(.init(commandId: envelope.commandId, seq: 1, result: .ok))
        try journal.confirmThrough(snapshotSeq: 500)
        try journal.observe(Fix.envelope(2, .taskUpdated(Fix.card("t-1")), commandId: envelope.commandId))
        try journal.observe(Fix.envelope(3, .wipRestored(.init(taskId: "t-1", runId: "other", wipRef: "refs/kaban/wip/r-1")), commandId: envelope.commandId))
        XCTAssertEqual(journal.records[0].phase, .awaitingEffect)
        try journal.observe(Fix.envelope(4, .wipRestored(.init(taskId: "t-1", runId: "r-1", wipRef: "refs/kaban/wip/r-1")), commandId: envelope.commandId))
        XCTAssertEqual(journal.records[0].phase, .applied)
        XCTAssertEqual(journal.records[0].confirmedSeq, 4)
    }

    @MainActor func testLegacyJournalRetainsItsEnvelopeButRequiresReconciliation() async throws {
        let storage = MemoryKeyValueStore()
        let envelope = CommandEnvelope(command: .pauseTask(taskId: "t-1"))
        let legacy = ClientCommandJournal.Record(envelope: envelope, sentAt: Fix.t0, reply: .init(commandId: envelope.commandId, seq: 8, result: .ok), eventSeq: 8, deliveryUncertain: false)
        storage.set(try JSONEncoder().encode([legacy]), forKey: "commands")
        let journal = try ClientCommandJournal(storage: storage, key: "commands")
        XCTAssertEqual(journal.records[0].scope, .task("t-1"))
        XCTAssertTrue(journal.records[0].isPending, "Old eventSeq did not preserve its confirming event type")
        try journal.confirmThrough(snapshotSeq: 8)
        XCTAssertFalse(journal.records[0].isPending)
        XCTAssertEqual(journal.records[0].envelope, envelope)
    }
}
