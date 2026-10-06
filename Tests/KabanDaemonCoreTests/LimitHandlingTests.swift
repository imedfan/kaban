import XCTest
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class LimitHandlingTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testRateLimitReleasesOnlyTheFailedRunAndSurvivesReopen() throws {
        let fixture = try store()
        try running("a", fixture.store)
        try running("b", fixture.store)
        let before = try task("a", fixture.store)
        XCTAssertEqual(try fixture.store.observeAgentFailure(taskId: "a", runId: "run-a", text: "Too many requests", commandId: UUID(), at: at), .rateLimit)
        let failed = try task("a", fixture.store)
        XCTAssertEqual(failed.machine.state, .retryWait(.rateLimit))
        XCTAssertEqual(failed.machine.attemptsUsed, before.machine.attemptsUsed)
        XCTAssertEqual(failed.machine.runsSinceHuman, before.machine.runsSinceHuman - 1)
        XCTAssertEqual(try task("b", fixture.store).machine.state, .running)
        guard case .rateLimited(let until, let step) = try fixture.store.getSnapshot().schedulerFlags.first else {
            return XCTFail("Missing cooldown")
        }
        XCTAssertEqual(step, 1)
        XCTAssertEqual(until, at.addingTimeInterval(15 * 60))
        let reopened = try KabanStore(path: fixture.path)
        XCTAssertEqual(try reopened.getSnapshot().schedulerFlags, try fixture.store.getSnapshot().schedulerFlags)
        let cooled = try task("a", reopened)
        XCTAssertFalse(try reopened.database.read { try KabanStore.canStart(cooled, at: self.at, db: $0) })
        XCTAssertEqual(try reopened.execute(.init(command: .resumeAfterRateLimit), now: { at }).result, .ok)
        XCTAssertTrue(try reopened.getSnapshot().schedulerFlags.isEmpty)
        try running("a", reopened, run: "run-a2", at: at.addingTimeInterval(10))
        _ = try reopened.observeAgentFailure(taskId: "a", runId: "run-a2", text: "rate limit", commandId: UUID(), at: at.addingTimeInterval(10))
        guard case .rateLimited(let second, let secondStep) = try reopened.getSnapshot().schedulerFlags.first else {
            return XCTFail("Missing second cooldown")
        }
        XCTAssertEqual(secondStep, 1)
        XCTAssertEqual(second, at.addingTimeInterval(10 + 15 * 60))
    }

    func testRepeatedRateLimitDuringCooldownUsesTheNextStep() throws {
        let fixture = try store()
        try running("a", fixture.store)
        try running("b", fixture.store)
        _ = try fixture.store.observeAgentFailure(taskId: "a", runId: "run-a", text: "rate_limit", commandId: UUID(), at: at)
        XCTAssertEqual(try task("b", fixture.store).machine.state, .running)
        _ = try fixture.store.observeAgentFailure(taskId: "b", runId: "run-b", text: "rate_limit", commandId: UUID(), at: at.addingTimeInterval(10))
        guard case .rateLimited(let until, let step) = try fixture.store.getSnapshot().schedulerFlags.first else {
            return XCTFail("Missing stepped cooldown")
        }
        XCTAssertEqual(step, 2)
        XCTAssertEqual(until, at.addingTimeInterval(10 + 30 * 60))
        XCTAssertEqual(try task("a", fixture.store).machine.state, .retryWait(.rateLimit))
        XCTAssertEqual(try task("b", fixture.store).machine.state, .retryWait(.rateLimit))
    }

    func testOmUsageDoesNotBlockCmAndUnknownUsageBlocksTheMac() throws {
        let fixture = try store()
        _ = try fixture.store.execute(.init(command: .setModelOverride(taskId: "b", stageId: "agent", model: "composer-2")), now: { at })
        try running("a", fixture.store)
        try queuedAgent("b", fixture.store)
        try queuedAgent("c", fixture.store)
        _ = try fixture.store.execute(.init(command: .setModelOverride(taskId: "c", stageId: "agent", model: "composer-2")), now: { at })
        let before = try task("a", fixture.store)
        XCTAssertEqual(try fixture.store.observeAgentFailure(taskId: "a", runId: "run-a", text: "usage limit", commandId: UUID(), at: at), .usageExhausted(.om))
        XCTAssertEqual(try task("a", fixture.store).machine.attemptsUsed, before.machine.attemptsUsed)
        XCTAssertEqual(try task("a", fixture.store).machine.state, .queued(.quotaOm))
        let cmTask = try task("c", fixture.store)
        let omTask = try task("a", fixture.store)
        XCTAssertTrue(try fixture.store.database.read { try KabanStore.canStart(cmTask, at: self.at, db: $0) })
        XCTAssertFalse(try fixture.store.database.read { try KabanStore.canStart(omTask, at: self.at, db: $0) })
        try running("b", fixture.store, run: "run-b")
        XCTAssertEqual(try fixture.store.observeAgentFailure(taskId: "b", runId: "run-b", text: "spendLimitHit resets 2026-10-06T12:00:00Z", commandId: UUID(), at: at), .usageExhausted(.cm))
        let flags = try fixture.store.getSnapshot().schedulerFlags
        XCTAssertFalse(flags.contains { if case .usageExhaustedUnknown = $0 { true } else { false } })
        guard case .poolUsageExhausted(let pool, let reset) = flags.first(where: { if case .poolUsageExhausted(.cm, _) = $0 { true } else { false } }) else {
            return XCTFail("Missing cm exhaustion")
        }
        XCTAssertEqual(pool, .cm)
        XCTAssertEqual(reset, Date(timeIntervalSince1970: 1_791_288_000))
        XCTAssertEqual(try task("b", fixture.store).machine.state, .queued(.quotaCm))
    }

    func testUnknownUsageBlocksEveryPoolAndASecretIsNotStored() throws {
        let fixture = try store()
        try running("a", fixture.store)
        try queuedAgent("b", fixture.store)
        try running("c", fixture.store, run: "run-c")
        _ = try fixture.store.execute(.init(command: .setModelOverride(taskId: "b", stageId: "agent", model: "composer-2")), now: { at })
        _ = try fixture.store.apply(.runFailed("run-a", .usageExhausted(nil)), taskId: "a", commandId: UUID(), at: at)
        guard case .usageExhaustedUnknown(let reset) = try fixture.store.getSnapshot().schedulerFlags.first(where: { if case .usageExhaustedUnknown = $0 { true } else { false } }) else {
            return XCTFail("Missing Mac usage flag")
        }
        XCTAssertEqual(reset, at.addingTimeInterval(6 * 60 * 60))
        let blocked = try task("b", fixture.store)
        XCTAssertFalse(try fixture.store.database.read { try KabanStore.canStart(blocked, at: self.at, db: $0) })
        let command = UUID()
        XCTAssertEqual(try fixture.store.observeAgentFailure(taskId: "c", runId: "run-c", text: "boom token=secret", commandId: command, at: at), .unknown)
        XCTAssertEqual(try fixture.store.observeAgentFailure(taskId: "c", runId: "run-c", text: "boom token=secret", commandId: command, at: at), .unknown)
        let detail = try fixture.store.getTaskDetail("c")
        XCTAssertEqual(detail.feed.filter { $0.kind == "limit_unclassified" }.count, 1)
        XCTAssertEqual(detail.feed.first { $0.kind == "limit_unclassified" }?.text, "Неклассифицированная ошибка.")
        XCTAssertEqual(try task("c", fixture.store).machine.state, .running)
        XCTAssertEqual(try task("c", fixture.store).machine.attemptsUsed, 0)
        let stored = try fixture.store.database.read { try Data.fetchAll($0, sql: "SELECT payload FROM task_detail") }
        XCTAssertFalse(stored.contains { String(data: $0, encoding: .utf8)?.contains("token=secret") == true })
    }

    func testSilentProbeIsOnePerModelAndDoesNotStartAProcess() throws {
        let fixture = try store()
        try running("a", fixture.store)
        _ = try fixture.store.apply(.runFailed("run-a", .silentExit), taskId: "a", commandId: UUID(), at: at)
        XCTAssertEqual(try task("a", fixture.store).machine.state, .retryWait(.silentExit))
        XCTAssertEqual(try task("a", fixture.store).machine.attemptsUsed, 0)
        let probes = try fixture.store.modelProbes()
        XCTAssertEqual(probes.map(\.model.rawValue), ["fake"])
        XCTAssertEqual(probes.first?.nextAt, at.addingTimeInterval(10 * 60))
        XCTAssertThrowsError(try fixture.store.apply(.start("run-a2"), taskId: "a", commandId: UUID(), at: at.addingTimeInterval(30))) { error in
            XCTAssertEqual(error as? StoreError, .schedulerBlocked)
        }
        try running("b", fixture.store)
        _ = try fixture.store.apply(.runFailed("run-b", .silentExit), taskId: "b", commandId: UUID(), at: at.addingTimeInterval(30))
        XCTAssertEqual(try fixture.store.modelProbes(), probes)
        XCTAssertEqual(try fixture.store.pendingEffects().flatMap(\.effects).contains { if case .requestModelProbe = $0 { true } else { false } }, false)
    }

    private let body = "Task\n\n## Критерии приёмки\n- [ ] Ready\n"

    private func store() throws -> (path: String, store: KabanStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        _ = try store.registerProject(ProjectSummary(id: "p", name: "P", path: "/never-read", mascotSeed: "p"), pipeline: try ManagedEngineFixture.pipeline(), commandId: UUID(), at: at)
        _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 4, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at)
        for id: TaskID in ["a", "b", "c"] {
            _ = try store.execute(.init(command: .createTask(projectId: "p", title: id.rawValue, body: body)), now: { at }, makeTaskID: { id })
        }
        return (path, store)
    }

    private func queuedAgent(_ id: TaskID, _ store: KabanStore) throws {
        _ = try store.apply(.start(RunID(rawValue: "intake-\(id.rawValue)")), taskId: id, commandId: UUID(), at: at)
        XCTAssertEqual(try task(id, store).machine.state.status, .queued)
    }

    private func running(_ id: TaskID, _ store: KabanStore, run: RunID? = nil, at: Date? = nil) throws {
        let moment = at ?? self.at
        let current = try task(id, store)
        if current.machine.state.status == .queued && current.machine.stageId.rawValue == "queue" {
            _ = try store.apply(.start(RunID(rawValue: "intake-\(id.rawValue)")), taskId: id, commandId: UUID(), at: moment)
        }
        let runId = run ?? RunID(rawValue: "run-\(id.rawValue)")
        _ = try store.apply(.start(runId), taskId: id, commandId: UUID(), at: moment)
        XCTAssertEqual(try task(id, store).machine.state, .running)
    }

    private func task(_ id: TaskID, _ store: KabanStore) throws -> DurableTask {
        try store.database.read { try KabanStore.task(id, db: $0) }
    }
}
