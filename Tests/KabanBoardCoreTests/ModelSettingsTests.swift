import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class ModelSettingsTests: XCTestCase {
    func testPickerRejectsAutoMissingForbiddenAndUnavailableButKeepsReviewSelectable() {
        let model = ModelInfo(id: "gpt-5", name: "GPT-5", pool: .om, needsReview: true)
        XCTAssertTrue(ModelSelection.selectable(model, flags: []))
        var invalid = model; invalid.id = "auto"
        XCTAssertFalse(ModelSelection.selectable(invalid, flags: []))
        invalid = model; invalid.missingSince = Date()
        XCTAssertFalse(ModelSelection.selectable(invalid, flags: []))
        invalid = model; invalid.forbidden = true
        XCTAssertFalse(ModelSelection.selectable(invalid, flags: []))
        let flag = ModelFlag(modelId: model.id, reason: .unavailable, requested: model.name, since: Date())
        XCTAssertFalse(ModelSelection.selectable(model, flags: [flag]))
        XCTAssertEqual(ModelSelection.family(model), "GPT")
    }
    func testLegacyUnknownAndConfirmedEmptyModelFactsRemainDistinct() throws {
        let legacy = try KabanCoding.makeDecoder().decode(Snapshot.self, from: KabanCoding.makeEncoder().encode(Fix.snapshot()))
        XCTAssertNil(legacy.modelCatalog); XCTAssertNil(legacy.modelPoolRules)
        XCTAssertFalse(BoardProjection(snapshot: legacy).ephemeral.modelCatalogKnown)
        var empty = legacy; empty.modelCatalog = []; empty.modelPoolRules = []
        let decoded = try KabanCoding.makeDecoder().decode(Snapshot.self, from: KabanCoding.makeEncoder().encode(empty))
        XCTAssertEqual(decoded.modelPoolRules, []); XCTAssertTrue(BoardProjection(snapshot: decoded).ephemeral.modelCatalogKnown)
        let detail = TaskDetail(seq: legacy.seq, task: Fix.card("a"), feed: [], runs: [])
        XCTAssertNil(try KabanCoding.makeDecoder().decode(TaskDetail.self, from: KabanCoding.makeEncoder().encode(detail)).modelStages)
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CommandError(code: "timeout", message: "Model test timed out")
    }
    @MainActor func testPoolRulesWaitForMatchingEventAndUseBackendResolvedPool() async throws {
        let client = ModelTestClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "models")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let store = ModelSettingsStore(client: client, session: session)
        XCTAssertEqual(store.rules, [])
        _ = await store.send(.setModelPoolRule(pattern: "gpt-*", pool: .cm))
        XCTAssertEqual(store.receipt?.phase, .awaitingEvent)
        XCTAssertEqual(store.rules, []); XCTAssertEqual(store.catalog.first?.pool, .om)
        let id = try XCTUnwrap(store.commandID)
        client.emit(.init(seq: 11, at: Date(), projectId: nil, commandId: id, event: .settingsChanged(.init(key: "global", value: "unrelated"))))
        try await wait { session.projection?.stateSeq == 11 }
        XCTAssertEqual(store.receipt?.phase, .awaitingEvent)
        var model = client.model; model.pool = .cm; model.needsReview = false
        client.emit(.init(seq: 12, at: Date(), projectId: nil, commandId: id, event: .settingsChanged(.init(key: "model_pool", value: "updated", modelCatalog: [model], modelPoolRules: [.init(pattern: "gpt-*", pool: .cm, source: .user)], modelFlags: []))))
        try await wait { store.receipt?.phase == .applied }
        XCTAssertEqual(store.rules?.first?.pattern, "gpt-*"); XCTAssertEqual(store.catalog.first?.pool, .cm)
        XCTAssertFalse(store.catalog.first?.needsReview ?? true)
    }
    @MainActor func testOverrideUsesOnlyChosenTaskStageAndPreservesSelectionWhenStale() async throws {
        let client = ModelTestClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "override")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let detail = TaskDetail(seq: 10, task: Fix.card("a"), feed: [], runs: [], modelStages: [
            .init(stageId: "dev", name: "Dev", stageModel: "old"), .init(stageId: "test", name: "Test", stageModel: "test-old")])
        let editor = try XCTUnwrap(TaskModelOverrideStore(detail: detail, session: session))
        XCTAssertEqual(editor.model, "old"); XCTAssertFalse(editor.canSubmit())
        editor.selectStage("test"); editor.model = "gpt-5"
        XCTAssertTrue(editor.canSubmit()); _ = await editor.submit()
        XCTAssertEqual(client.sent.last?.command, .setModelOverride(taskId: Fix.card("a").id, stageId: "test", model: "gpt-5"))
        XCTAssertEqual(editor.receipt?.phase, .awaitingEvent)
        XCTAssertNil(editor.stage?.overrideModel)
        var changed = Fix.card("a"); changed.updatedAt = Date()
        client.emit(.init(seq: 11, at: Date(), projectId: changed.projectId, commandId: editor.commandID, event: .taskUpdated(changed)))
        try await wait { editor.receipt?.phase == .applied }
        XCTAssertTrue(editor.stale); XCTAssertEqual(editor.model, "gpt-5")
        let fresh = TaskDetail(seq: 11, task: changed, feed: [], runs: [], modelStages: detail.modelStages)
        editor.reconcile(fresh); XCTAssertFalse(editor.stale); XCTAssertEqual(editor.model, "gpt-5")
        editor.model = "unknown"; XCTAssertFalse(editor.canSubmit())
    }
    @MainActor func testFailedRefreshKeepsAuthoritativeCatalogAndRules() async throws {
        let client = ModelTestClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "refresh")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let store = ModelSettingsStore(client: client, session: session)
        client.failure = .init(code: "model_catalog_refresh_failed", message: "Refresh failed")
        let before = store.catalog
        let accepted = await store.send(.refreshModelCatalog)
        XCTAssertFalse(accepted); XCTAssertEqual(store.catalog, before); XCTAssertEqual(store.rules, [])
        XCTAssertNotNil(store.error)
    }
    @MainActor func testLateCatalogReadFromDisconnectedSessionCannotPopulateUnknownCatalog() async throws {
        let client = ModelTestClient(); client.provideCatalog = false; client.holdRead = true
        let session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "late-models")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let store = ModelSettingsStore(client: client, session: session)
        let read = Task { await store.loadIfNeeded() }
        try await wait { client.heldRead != nil }
        try session.consume(.connection(.reconnecting(lastSeq: 10)))
        let held = try XCTUnwrap(client.heldRead)
        held.1.resume(returning: .init(commandId: held.0.commandId, seq: nil, result: .models([client.model])))
        await read.value
        XCTAssertFalse(store.catalogKnown); XCTAssertEqual(store.catalog, [])
        XCTAssertEqual(store.rules, [])
    }

    @MainActor func testOldVolatileFlagsAndCatalogCannotUndoConfirmedModelSettings() async throws {
        let client = ModelTestClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "model-seq")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let cursor = try XCTUnwrap(session.ephemeralCursor)
        let oldFlag = ModelFlag(modelId: client.model.id, reason: .unavailable, requested: "GPT-5", since: Date())
        var snapshot = try await client.getSnapshot(); snapshot.seq = 11
        try session.consume(.replacement(.init(snapshot: snapshot, cursor: cursor, current: [
            .init(cursor: cursor, afterSeq: 10, at: Date(), event: .modelFlagsChanged([oldFlag])),
            .init(cursor: cursor, afterSeq: 10, at: Date(), event: .modelCatalogChanged([]))])))
        XCTAssertEqual(session.projection?.ephemeral.modelFlags, [])
        XCTAssertEqual(session.projection?.ephemeral.modelCatalog, [client.model])
        try session.consume(.event(.init(seq: 12, at: Date(), projectId: nil, event: .settingsChanged(.init(key: "model_flag", value: "cleared", modelCatalog: [client.model], modelFlags: [])))))
        try session.consume(.ephemeral(.init(cursor: .init(sessionId: cursor.sessionId, offset: cursor.offset + 1), afterSeq: 11, at: Date(), event: .modelFlagsChanged([oldFlag]))))
        try session.consume(.ephemeral(.init(cursor: .init(sessionId: cursor.sessionId, offset: cursor.offset + 2), afterSeq: 11, at: Date(), event: .modelCatalogChanged([]))))
        XCTAssertEqual(session.projection?.ephemeral.modelFlags, [])
        XCTAssertEqual(session.projection?.ephemeral.modelCatalog, [client.model])
    }

}

@MainActor private final class ModelTestClient: KabanClient {
    let model = ModelInfo(id: "gpt-5", name: "GPT-5", pool: .om, needsReview: true)
    var failure: CommandError?
    var provideCatalog = true
    var holdRead = false
    var heldRead: (CommandEnvelope, CheckedContinuation<CommandReply, Never>)?
    var sent: [CommandEnvelope] = []
    var continuation: AsyncStream<EventEnvelope>.Continuation?
    func getSnapshot() async throws -> Snapshot {
        var snapshot = Fix.snapshot(tasks: [Fix.card("a")]); snapshot.modelCatalog = provideCatalog ? [model] : nil; snapshot.modelPoolRules = []; return snapshot
    }
    func synchronize() async throws -> SnapshotReplacement {
        .init(snapshot: try await getSnapshot(), cursor: .init(sessionId: UUID(), offset: 0), current: [])
    }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: ["snapshot", "command", "subscribe", "synchronize"].map { .init(name: $0, supported: true) },
              commands: CommandName.allCases.map { .init(name: $0.rawValue, support: .supported) })
    }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { continuation = $0 } }
    func emit(_ envelope: EventEnvelope) { continuation?.yield(envelope) }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        sent.append(envelope)
        if envelope.command == .listModels && holdRead { return await withCheckedContinuation { heldRead = (envelope, $0) } }
        return .init(commandId: envelope.commandId, seq: failure == nil ? 11 : nil, result: failure.map(CommandResult.error) ?? .ok)
    }
}
