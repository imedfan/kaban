import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

@MainActor final class IncidentsStoreTests: XCTestCase {
    private func incident(_ id: IncidentID, project: ProjectID = "hidden", resolved: Bool = false) -> Incident {
        .init(id: id, projectId: project, taskId: "removed-task", runId: nil,
              kind: resolved ? .init(rawValue: "future_violation") : .refsMoved,
              rolledBack: [], openedAt: Fix.t0, resolvedAt: resolved ? Fix.t0 : nil)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CommandError(code: "test_timeout", message: "Incident read timeout")
    }
    func testHiddenAndDeletedHistoryUsesAllProjectsAndNeverCountsRows() async throws {
        let client = IncidentReadClient(values: [incident("open"), incident("history", project: "deleted", resolved: true)])
        let session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "incidents")
        let loop = Task { await session.run() }; defer { loop.cancel(); session.stop() }
        try await wait { session.canSend }; session.hide("hidden")
        let store = IncidentsStore(client: client, session: session)
        await store.refresh()
        XCTAssertTrue(store.isCurrent)
        XCTAssertEqual(client.commands.last?.command, .listIncidents(projectIds: nil, state: .all))
        XCTAssertEqual(store.visible.map(\.id), ["open"])
        XCTAssertEqual(session.projection?.openIncidentCount, 7)
        store.filter = .all; store.selectedID = "history"
        XCTAssertEqual(store.visible.map(\.id), ["open", "history"])
        XCTAssertEqual(store.selected?.kind.rawValue, "future_violation")
        XCTAssertNil(session.projection?.projects["deleted"])
        XCTAssertEqual(session.projection?.openIncidentCount, 7)
    }
    func testLateReadCannotOverwriteAnIncidentEventAndFailureKeepsCache() async throws {
        let old = incident("old"), new = incident("new")
        let client = IncidentReadClient(values: [old])
        let session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "late")
        let loop = Task { await session.run() }; defer { loop.cancel(); session.stop() }
        try await wait { session.canSend }
        let store = IncidentsStore(client: client, session: session)
        await store.refresh(); client.hold = true
        let read = Task { await store.refresh() }
        try await wait { client.held != nil }
        try session.consume(.event(Fix.envelope(11, .incidentOpened(new))))
        client.resume(); await read.value
        XCTAssertEqual(store.records, [old]); XCTAssertFalse(store.isCurrent)
        client.hold = false; client.values = [old, new]
        await store.refresh(); XCTAssertTrue(store.isCurrent)
        client.fail = true; await store.refresh()
        XCTAssertEqual(store.records, [old, new])
        guard case .failed = store.readState else { return XCTFail("Read failure missing") }
        let before = store.readKey
        try session.consume(.connection(.reconnecting(lastSeq: 11)))
        XCTAssertNotEqual(store.readKey, before)
        XCTAssertFalse(store.isCurrent)
    }
    func testSnapshotRevisionAndStoppedReaderDoNotRestoreOldResults() async throws {
        let client = IncidentReadClient(values: [incident("old")])
        let session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "stopped")
        let loop = Task { await session.run() }; defer { loop.cancel(); session.stop() }
        try await wait { session.canSend }
        let store = IncidentsStore(client: client, session: session)
        await store.refresh()
        let before = store.readKey
        try session.consume(.replacement(try await client.synchronize()))
        XCTAssertNotEqual(before, store.readKey)
        client.hold = true
        let read = Task { await store.refresh() }
        try await wait { client.held != nil }
        store.stop(); client.values = [incident("new")]; client.resume(); await read.value
        XCTAssertEqual(store.records.map(\.id), ["old"])
        XCTAssertEqual(store.readState, .unknown)
    }
}

@MainActor private final class IncidentReadClient: KabanClient {
    let base = MockKabanClient(snapshot: Fix.snapshot(projects: [Fix.project(openIncidentCount: 7), Fix.project("hidden")], openIncidents: 7))
    var values: [Incident]
    var commands: [CommandEnvelope] = []
    var hold = false
    var fail = false
    var held: (CommandEnvelope, CheckedContinuation<CommandReply, Never>)?
    init(values: [Incident]) { self.values = values }
    func getSnapshot() async throws -> Snapshot { try await base.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await base.synchronize() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { base.updates() }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: [.init(name: "synchronize", supported: true)], commands: CommandName.allCases.map { .init(name: $0.rawValue, support: .supported) })
    }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        guard case .listIncidents = envelope.command else { return try await base.send(envelope) }
        commands.append(envelope)
        if hold { return await withCheckedContinuation { held = (envelope, $0) } }
        if fail { throw CommandError(code: "read_failed", message: "Read failed") }
        return .init(commandId: envelope.commandId, seq: nil, result: .incidents(values))
    }
    func resume() {
        guard let (envelope, continuation) = held else { return }
        held = nil; continuation.resume(returning: .init(commandId: envelope.commandId, seq: nil, result: .incidents(values)))
    }
}
