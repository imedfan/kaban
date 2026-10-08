import Foundation
import XCTest
@testable import KabanProtocol

final class RoundTripTests: XCTestCase {
    let encoder = KabanCoding.makeEncoder(pretty: true)
    let decoder = KabanCoding.makeDecoder()
    func testMergeQueueAndMaterialsRemainBackwardCompatible() throws {
        var card = Samples.tasks[0]
        card.mergeQueueSequence = 42; try roundTrip(card)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(card)) as? [String: Any])
        object.removeValue(forKey: "mergeQueueSequence")
        XCTAssertNil(try decoder.decode(TaskCard.self, from: JSONSerialization.data(withJSONObject: object)).mergeQueueSequence)
        object.removeValue(forKey: "title")
        XCTAssertThrowsError(try decoder.decode(TaskCard.self, from: JSONSerialization.data(withJSONObject: object)))
        try roundTrip(LocalMergeResult(baseCommit: "base", commit: "tip", ref: "refs/heads/main"))
        try roundTrip(MergeConflictMaterial(files: ["Path with space.swift", "Длинный путь/👋.swift"]))
    }

    func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try encoder.encode(value)
        let back = try decoder.decode(T.self, from: data)
        XCTAssertEqual(back, value, String(decoding: data, as: UTF8.self), file: file, line: line)
    }

    func testSuspiciousFilesSurviveResync() throws {
        // Набор живёт в TaskCard (снимок, taskUpdated), принятые — в TaskDetail (§8.2).
        try roundTrip(Samples.taskDetail)
        let card = try XCTUnwrap(Samples.tasks.first { $0.id == "t-8" })
        XCTAssertEqual(card.suspiciousFiles.count, 2)
        let json = String(decoding: try encoder.encode(Samples.taskDetail), as: UTF8.self)
        XCTAssertTrue(json.contains("\"acceptedFiles\""))
        try roundTrip(Command.acceptSuspiciousFiles(taskId: "t-8", files: [FileBlobRef(path: ".env.local", blob: "a1b2c3")]))
    }

    func testAllTaskStatesRoundTrip() throws {
        var states: [TaskState] = [.queued(nil), .running, .gating, .paused, .done, .cancelled]
        states += QueuedReason.allCases.map { .queued($0) }
        states += RetryWaitReason.allCases.map { .retryWait($0) }
        states += WaitingHumanReason.allCases.map { .waitingHuman($0) }
        states += BlockedReason.allCases.map { .blocked($0) }
        for s in states { try roundTrip(s) }
    }

    func testTaskStateWireIsFlat() throws {
        let json = String(decoding: try KabanCoding.makeEncoder().encode(TaskState.waitingHuman(.suspiciousFiles)), as: UTF8.self)
        XCTAssertEqual(json, #"{"reason":"suspicious_files","status":"waiting_human"}"#)
    }

    func testFlagsRoundTrip() throws { for f in Samples.flags { try roundTrip(f) } }
    func testSnapshotRoundTrip() throws { try roundTrip(Samples.snapshot) }
    func testEventsRoundTrip() throws { for e in Samples.events { try roundTrip(e) } }
    func testEphemeralRoundTrip() throws { for e in Samples.ephemeral { try roundTrip(e) } }
    func testCommandsRoundTrip() throws { for c in Samples.commands { try roundTrip(c) } }

    func testUnknownJournalEventDoesNotThrow() throws {
        let json = #"{"seq":7,"at":"2026-10-04T08:00:00.000Z","event":{"type":"somethingFromTheFuture","data":{"x":1}}}"#
        let env = try decoder.decode(EventEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.event, .unknown(type: "somethingFromTheFuture"))
    }

    func testPoolFlagIsNotMacLevel() {
        XCTAssertEqual(SchedulerFlag.poolUsageExhausted(.cm, resetsAt: nil).level, .pool)
        XCTAssertEqual(SchedulerFlag.usageExhaustedUnknown(resetsAt: nil).level, .mac)
    }

    func testCountersRules() {
        XCTAssertFalse(RetryWaitReason.silentExit.chargesAttempt)
        XCTAssertFalse(RetryWaitReason.rateLimit.chargesAttempt)
        XCTAssertTrue(RetryWaitReason.gateFailed.chargesAttempt)
        XCTAssertFalse(TaskState.waitingHuman(.review).countsTowardMaxWaitingHuman)
        XCTAssertTrue(TaskState.waitingHuman(.suspiciousFiles).countsTowardMaxWaitingHuman)
        XCTAssertTrue(TaskStatus.retryWait.occupiesWIP)
        XCTAssertFalse(TaskStatus.waitingHuman.occupiesWIP)
    }

    func testModelPools() {
        let rules = ModelPoolRule.builtin
        XCTAssertEqual(ModelPoolResolver.pool(for: "composer-1", rules: rules), .cm)
        XCTAssertEqual(ModelPoolResolver.pool(for: "claude-4.5-opus", rules: rules), .om)
        let user = rules + [ModelPoolRule(pattern: "cheap-model", pool: .cm, source: .user)]
        XCTAssertEqual(ModelPoolResolver.pool(for: "cheap-model", rules: user), .cm)
    }

    func testPipelineValidity() {
        XCTAssertTrue(Samples.pipeline.isValid, "предупреждение не делает пайплайн невалидным")
        XCTAssertFalse(Samples.invalidPipeline.isValid)
    }
}

final class QuotaTests: XCTestCase {
    let cal = Calendar.utc
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }

    func testCycleStartIsCalendarMonthNotThirtyDays() {
        let end = date(2026, 10, 31)
        XCTAssertEqual(BillingCycle.startFallback(end: end), date(2026, 9, 30))   // в сентябре нет 31-го
        XCTAssertEqual(BillingCycle.startFallback(end: date(2026, 3, 17)), date(2026, 2, 17))
        XCTAssertEqual(BillingCycle.startFallback(end: date(2026, 3, 31)), date(2026, 2, 28))
        XCTAssertNotEqual(BillingCycle.startFallback(end: date(2026, 3, 17)), date(2026, 3, 17).addingTimeInterval(-30 * 86400))
    }

    func testExplicitStartWins() {
        let q = QuotaState(cm: 1, om: 2, billingCycleStart: date(2026, 9, 20), billingCycleEnd: date(2026, 10, 17), fetchedAt: Date())
        XCTAssertEqual(q.effectiveCycleStart(), date(2026, 9, 20))
    }

    func testEpochMillisString() {
        XCTAssertEqual(BillingCycle.parseEpochMillis("1792195200000"), Date(timeIntervalSince1970: 1_792_195_200))
        XCTAssertNil(BillingCycle.parseEpochMillis(nil))
        XCTAssertNil(BillingCycle.parseEpochMillis("скоро"))
    }

    func testMissingPercentIsNoDataNotZero() throws {
        let json = #"{"fetchedAt":"2026-10-04T08:00:00.000Z"}"#
        let q = try KabanCoding.makeDecoder().decode(QuotaState.self, from: Data(json.utf8))
        XCTAssertNil(q.cm); XCTAssertNil(q.om); XCTAssertNil(q.percentUsed(.om))
    }

    func testStaleness() {
        let q = QuotaState(cm: 1, om: 1, billingCycleEnd: nil, fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(q.isStale(now: Date(timeIntervalSince1970: 29 * 60)))
        XCTAssertTrue(q.isStale(now: Date(timeIntervalSince1970: 31 * 60)))
    }
}
