import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class MacSettingsTests: XCTestCase {
    func testUnknownStaleDisabledAndExhaustedQuotaRemainDistinct() {
        let now = Fix.t0, options = QuotaOptions(enabled: true, consent: true)
        let nilReading = QuotaState(cm: nil, om: 0, billingCycleEnd: nil, fetchedAt: now)
        XCTAssertNil(QuotaPresentation(pool: .cm, quota: nilReading, options: options, flags: [], now: now).percent)
        XCTAssertEqual(QuotaPresentation(pool: .om, quota: nilReading, options: options, flags: [], now: now).percent, 0)
        let stale = QuotaState(cm: 46, om: 93, billingCycleEnd: now.addingTimeInterval(100), fetchedAt: now.addingTimeInterval(-1801))
        let view = QuotaPresentation(pool: .cm, quota: stale, options: options, flags: [], now: now)
        XCTAssertNil(view.percent); XCTAssertNil(view.thresholdUsed); XCTAssertNil(view.cycleFraction); XCTAssertNil(view.resetCountdown)
        XCTAssertTrue(view.message.contains("Нет свежих"))
        let disabled = QuotaPresentation(pool: .cm, quota: nilReading, options: .init(enabled: false, consent: false), flags: [], now: now)
        XCTAssertNil(disabled.percent); XCTAssertEqual(disabled.message, "Выключено")
        let exhausted = QuotaPresentation(pool: .om, quota: nil, options: options, flags: [.poolUsageExhausted(.om, resetsAt: nil)], now: now)
        XCTAssertEqual(exhausted.percent, 100); XCTAssertEqual(exhausted.message, "Исчерпан"); XCTAssertNil(exhausted.resetAt)
        let invalid = QuotaState(cm: .infinity, om: -1, billingCycleEnd: nil, fetchedAt: now)
        XCTAssertNil(QuotaPresentation(pool: .cm, quota: invalid, options: options, flags: [], now: now).percent)
    }
    func testCycleUsesCalendarMonthAndRemainingThreshold() throws {
        let format = ISO8601DateFormatter()
        let end = try XCTUnwrap(format.date(from: "2026-03-31T12:00:00Z"))
        let now = try XCTUnwrap(format.date(from: "2026-03-15T00:00:00Z"))
        let quota = QuotaState(cm: 46, om: nil, billingCycleEnd: end, fetchedAt: now)
        let start = try XCTUnwrap(quota.effectiveCycleStart())
        XCTAssertEqual(format.string(from: start), "2026-02-28T12:00:00Z")
        let view = QuotaPresentation(pool: .cm, quota: quota, options: .init(enabled: true, consent: true, thresholdCm: 17), flags: [], now: now)
        XCTAssertEqual(try XCTUnwrap(view.cycleFraction), 14.5 / 31, accuracy: 0.00001)
        XCTAssertEqual(view.thresholdUsed, 83)
        XCTAssertEqual(view.resetCountdown, "Сброс через 16 д")
        let expired = QuotaPresentation(pool: .cm, quota: nil, options: .init(enabled: true, consent: true), flags: [.poolUsageExhausted(.cm, resetsAt: now)], now: now)
        XCTAssertEqual(expired.resetCountdown, "Ожидаем обновления источника после сброса")
        let disabled = QuotaPresentation(pool: .cm, quota: quota, options: .init(enabled: false, consent: false), flags: [.poolUsageExhausted(.cm, resetsAt: end)], now: now)
        XCTAssertNil(disabled.resetCountdown)
    }
    func testAllFlagsHaveIndependentRoutesWithoutInventedReset() {
        let flags: [SchedulerFlag] = [.runnerUnavailable(.runnerAuth), .usageExhaustedUnknown(resetsAt: nil),
                                     .rateLimited(cooldownUntil: Fix.t0, step: 1), .macPaused,
                                     .poolUsageExhausted(.om, resetsAt: nil), .projectUnavailable(Fix.project, .noPipeline, detail: nil)]
        let rows = flags.map(SchedulerFlagPresentation.init)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0].command, .recheck(scope: .runner))
        XCTAssertEqual(rows[2].command, .resumeAfterRateLimit)
        XCTAssertEqual(rows[3].command, .resumeAll)
        XCTAssertTrue(rows[1].detail.contains("неизвестен"))
        XCTAssertEqual(rows[5].project, Fix.project)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Mac settings timeout")
        throw CommandError(code: "test_timeout", message: "Mac settings timeout")
    }
    @MainActor func testConsentPendingEventAndDraftSurviveReopen() async throws {
        let client = MacTestClient(), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "mac")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let editor = MacSettingsStore(session: session, storage: storage, key: "mac.draft"); editor.begin()
        var options = try XCTUnwrap(editor.options); options.enabled = true
        editor.editOptions(options)
        XCTAssertFalse(editor.canSubmit(.quota)); XCTAssertTrue(client.sent.isEmpty)
        options.consent = true; options.thresholdOm = 23; editor.editOptions(options); editor.editInterval("900")
        XCTAssertTrue(editor.canSubmit(.quota)); _ = await editor.submit(.quota)
        XCTAssertEqual(session.projection?.settings?.quotaOptions.enabled, false)
        XCTAssertEqual(editor.receipt?.phase, .awaitingEvent)
        let reopened = MacSettingsStore(session: session, storage: storage, key: "mac.draft")
        XCTAssertEqual(reopened.interval, "900"); XCTAssertEqual(reopened.options?.thresholdOm, 23)
        let id = try XCTUnwrap(editor.commandID)
        let chosen = QuotaOptions(enabled: true, consent: true, pollInterval: 900, thresholdOm: 23)
        client.snapshot.settings = .init(maxConcurrentRuns: 4, quotaOptions: chosen, quotaConsentedAt: Fix.t0)
        client.snapshot.seq = 11
        client.emit(Fix.envelope(11, .settingsChanged(.init(key: "global", value: "confirmed", settings: client.snapshot.settings)), commandId: id, projectId: nil))
        try await wait { editor.receipt?.phase == .applied }
        editor.observeOutcome()
        XCTAssertEqual(session.projection?.settings?.quotaOptions, chosen)
        XCTAssertFalse(editor.stale(.quota)); XCTAssertFalse(editor.canSubmit(.quota))
        XCTAssertEqual(session.projection?.tasks["running"]?.state, .running)
        editor.editInterval("1800")
        let editedAfterSuccess = MacSettingsStore(session: session, storage: storage, key: "mac.draft")
        editedAfterSuccess.observeOutcome()
        XCTAssertEqual(editedAfterSuccess.interval, "1800")
    }
    @MainActor func testStaleExternalSettingsAndRejectedSendPreserveIntent() async throws {
        let client = MacTestClient(), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "stale-mac")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let editor = MacSettingsStore(session: session, storage: storage, key: "draft"); editor.begin(); editor.editCeiling("7")
        var settings = try XCTUnwrap(client.snapshot.settings); settings.maxConcurrentRuns = 2
        try session.consume(.event(Fix.envelope(11, .settingsChanged(.init(key: "global", value: "external", settings: settings)), projectId: nil)))
        XCTAssertTrue(editor.stale(.ceiling)); XCTAssertFalse(editor.canSubmit(.ceiling)); XCTAssertEqual(editor.ceiling, "7")
        editor.useCurrent(); XCTAssertTrue(editor.canSubmit(.ceiling))
        client.failure = .init(code: "invalid_request", message: "Rejected ceiling")
        _ = await editor.submit(.ceiling)
        XCTAssertEqual(editor.ceiling, "7"); XCTAssertNotNil(editor.error)
        let reopened = MacSettingsStore(session: session, storage: storage, key: "draft")
        XCTAssertEqual(reopened.ceiling, "7")
        try session.consume(.connection(.reconnecting(lastSeq: 11)))
        XCTAssertFalse(reopened.canSubmit(.ceiling))
    }
}

@MainActor private final class MacTestClient: KabanClient {
    var snapshot: Snapshot = {
        var value = Fix.snapshot(tasks: [Fix.card("running", state: .running)])
        value.settings = .init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)); return value
    }()
    var sent: [CommandEnvelope] = []
    var failure: CommandError?
    private var continuation: AsyncStream<EventEnvelope>.Continuation?
    func getSnapshot() async throws -> Snapshot { snapshot }
    func synchronize() async throws -> SnapshotReplacement { .init(snapshot: snapshot, cursor: .init(sessionId: UUID(), offset: 0), current: []) }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: ["snapshot", "command", "subscribe", "synchronize"].map { .init(name: $0, supported: true) }, commands: CommandName.allCases.map { .init(name: $0.rawValue, support: .supported) })
    }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { continuation = $0 } }
    func emit(_ value: EventEnvelope) { continuation?.yield(value) }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        sent.append(envelope)
        return .init(commandId: envelope.commandId, seq: nil, result: failure.map(CommandResult.error) ?? .ok)
    }
}
