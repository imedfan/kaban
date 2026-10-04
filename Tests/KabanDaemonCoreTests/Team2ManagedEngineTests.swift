import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
import KabanBoardCore
@testable import KabanDaemonCore

final class Team2ManagedEngineTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 123)
    func pipeline() throws -> PipelineConfig {
        let result = PipelineValidator.validate(yaml: """
        version: 1
        board: {max_waiting_human: 2, bounce_limit_total: 5, max_runs_per_task: 12}
        stages:
          - id: queue
            name: Queue
            kind: queue
            on_success: agent
          - id: agent
            name: Agent
            kind: agent
            wip: 2
            agent: {harness: cursor-cli, model: fake, skill: test.md, permissions: write, mcp: [kaban]}
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review
          - id: review
            name: Review
            kind: human
            wip: 1
            on_success: done
          - id: done
            name: Done
            kind: terminal
        """)
        XCTAssertTrue(result.errors.allSatisfy { $0.code == "merge_count" }, "\(result.errors)")
        return try XCTUnwrap(result.config)
    }
    func fixture(settings: Bool = true) throws -> (URL, KabanStore, PipelineConfig) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let store = try KabanStore(path: url.path); let p = try pipeline()
        _ = try store.registerProject(ProjectSummary(id: "p", name: "P", path: "/never-read", mascotSeed: "seed"), pipeline: p, commandId: UUID(), at: at)
        if settings { _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 2, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at) }
        return (url, store, p)
    }
    @discardableResult func create(_ store: KabanStore, id: TaskID = "t", priority: Int = 0, acceptance: Bool = true) throws -> DurableReceipt {
        try store.createTask(card: TaskCard(id: id, projectId: "p", title: "Task", stageId: "ignored", state: .queued(nil), priority: priority, hasAcceptanceCriteria: acceptance, updatedAt: at), body: "# Exact\n\n- criterion\n", commandId: UUID(), at: at)
    }
    func tick(_ store: KabanStore) throws -> TickReceipt { try store.tick(tickId: UUID(), runId: RunID(rawValue: UUID().uuidString), at: at) }
    func launch(_ store: KabanStore) throws -> PendingEffect { try XCTUnwrap(store.pendingEffectItems().first { if case .startAgentRun = $0.effect { true } else { false } }) }
    func drain(_ store: KabanStore) throws {
        for _ in 0..<8 {
          let effects = try store.pendingEffectItems()
          if effects.isEmpty { return }
          for effect in effects {
            let result = try FakeDriver.result(for: effect, agent: .completed(summary: "Explicit fixture completion"))
            _ = try store.deliverFake(effectId: effect.id, result: result, at: at)
          }
        }
        XCTFail("Fake drain did not converge")
    }
    func testExactQueriesExplicitSettingsAndFullReopenedHumanFlow() throws {
        let (url, store, _) = try fixture(settings: false); defer { try? FileManager.default.removeItem(at: url) }
        _ = try create(store)
        XCTAssertNil(try store.getSnapshot().settings)
        XCTAssertThrowsError(try tick(store))
        let settings = GlobalSettings(maxConcurrentRuns: 1, quotaOptions: QuotaOptions(enabled: false, consent: true, pollInterval: 900, thresholdCm: 17, thresholdOm: 23), quotaConsentedAt: at)
        _ = try store.setSettings(settings, commandId: UUID(), at: at)
        XCTAssertEqual(try store.getSnapshot().settings, settings)
        XCTAssertEqual(try store.getTaskDetail("t").body, "# Exact\n\n- criterion\n")
        _ = try tick(store); _ = try tick(store)
        let running = try KabanStore(path: url.path); let first = try launch(running)
        let question = try running.deliverFake(effectId: first.id, result: .question("Which?"), at: at)
        XCTAssertEqual(question.task.machine.state, .waitingHuman(.question))
        XCTAssertEqual(try running.deliverFake(effectId: first.id, result: .question("Which?"), at: Date()), question)
        XCTAssertThrowsError(try running.deliverFake(effectId: first.id, result: .completed(summary: "wrong"), at: at))
        let waiting = try KabanStore(path: url.path); let detail = try waiting.getTaskDetail("t")
        XCTAssertEqual(detail.runs.first?.endReason, .askedHuman)
        let request = try XCTUnwrap(detail.humanRequests.first?.requestId)
        XCTAssertThrowsError(try waiting.apply(.answer(text: "Yes", requestId: "foreign"), taskId: "t", commandId: UUID(), at: at))
        let answerId = UUID()
        let answer = try waiting.apply(.answer(text: "Yes", requestId: request), taskId: "t", commandId: answerId, at: at)
        XCTAssertEqual(try waiting.apply(.answer(text: "Yes", requestId: request), taskId: "t", commandId: answerId, at: Date()), answer)
        _ = try tick(waiting); let second = try launch(waiting)
        if case .startAgentRun(let r) = second.effect { XCTAssertTrue(r.prompt.contains(.humanAnswer("Yes"))) }
        let completed = try waiting.deliverFake(effectId: second.id, result: .completed(summary: "Finished"), at: at)
        XCTAssertEqual(completed.task.machine.state, .gating)
        try drain(waiting); _ = try tick(waiting)
        XCTAssertEqual(try waiting.getTaskDetail("t").task.state, .waitingHuman(.review))
        XCTAssertFalse(try waiting.getSnapshot().schedulerFlags.contains(.intakePaused("p")))
        _ = try waiting.apply(.approve, taskId: "t", commandId: UUID(), at: at)
        try drain(waiting)
        let done = try KabanStore(path: url.path)
        XCTAssertEqual(try done.getTaskDetail("t").task.state, .done)
        XCTAssertEqual(try done.getTaskDetail("t").artifacts.count, 1)
        XCTAssertEqual(try done.getTaskDetail("t").humanRequests.count, 1)
        XCTAssertTrue(try done.pendingEffectItems().isEmpty)
        XCTAssertEqual(try done.deliverFake(effectId: second.id, result: .completed(summary: "Finished"), at: at), completed)
    }
    func testInjectedResultFailureRollsBackResultStateAndAudit() throws {
        let (url, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try create(store); _ = try tick(store); _ = try tick(store)
        let pending = try launch(store); let before = try store.getTaskDetail("t")
        let inspection = try DatabaseQueue(path: url.path)
        try inspection.write { db in try db.execute(sql: "CREATE TRIGGER injected BEFORE UPDATE OF result ON effect BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        XCTAssertThrowsError(try store.deliverFake(effectId: pending.id, result: .question("Q"), at: at))
        XCTAssertEqual(try store.getTaskDetail("t"), before)
        XCTAssertTrue(try store.pendingEffectItems().contains(pending))
        try inspection.write { db in try db.execute(sql: "DROP TRIGGER injected") }
        _ = try store.deliverFake(effectId: pending.id, result: .question("Q"), at: at)
        XCTAssertEqual(try store.getTaskDetail("t").humanRequests.count, 1)
    }
    func testAdmissionPauseBeforeAndAfterAndReplayTick() throws {
        let (url, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try create(store); _ = try tick(store); _ = try tick(store)
        _ = try store.deliverFake(effectId: launch(store).id, result: .completed(summary: "Ready"), at: at); try drain(store)
        _ = try store.apply(.pause, taskId: "t", commandId: UUID(), at: at)
        XCTAssertEqual(try store.getSnapshot().stageLoad.first { $0.stageId == "review" }?.wipUsed, 0)
        _ = try store.apply(.resume, taskId: "t", commandId: UUID(), at: at)
        let token = UUID(); let receipt = try store.tick(tickId: token, runId: "review", at: at)
        XCTAssertEqual(try store.tick(tickId: token, runId: "different", at: Date()), receipt)
        _ = try store.apply(.pause, taskId: "t", commandId: UUID(), at: at)
        XCTAssertEqual(try store.getSnapshot().stageLoad.first { $0.stageId == "review" }?.wipUsed, 1)
        let reopened = try KabanStore(path: url.path)
        _ = try reopened.apply(.resume, taskId: "t", commandId: UUID(), at: at)
        XCTAssertEqual(try reopened.getTaskDetail("t").task.state, .waitingHuman(.review))
        XCTAssertEqual(try reopened.getSnapshot().stageLoad.first { $0.stageId == "review" }?.wipUsed, 1)
        _ = try reopened.apply(.approve, taskId: "t", commandId: UUID(), at: at)
        XCTAssertEqual(try reopened.getSnapshot().stageLoad.first { $0.stageId == "review" }?.wipUsed, 0)
    }
    func testBlockedIntakeDoesNotBlockEligibleAndGlobalLimit() throws {
        let (url, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try create(store, id: "blocked", priority: 100, acceptance: false)
        _ = try create(store, id: "eligible", priority: 2)
        XCTAssertEqual(try tick(store).transitions.first?.task.card.id, "eligible")
        _ = try tick(store)
        _ = try create(store, id: "next"); _ = try tick(store)
        _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 1, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at)
        XCTAssertTrue(try tick(store).transitions.isEmpty)
        XCTAssertEqual(try store.getSnapshot().tasks.filter { $0.state.status == .running }.count, 1)
    }
    func testWeightedCursorAcrossReopenAndCommandConflict() throws {
        let (url, store, p) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let weighted = ProjectSummary(id: "p", name: "P", path: "/never-read", weight: 3, mascotSeed: "seed")
        _ = try store.registerProject(weighted, pipeline: p, commandId: UUID(), at: at)
        _ = try store.registerProject(ProjectSummary(id: "q", name: "Q", path: "/never-read", weight: 1, mascotSeed: "seed"), pipeline: p, commandId: UUID(), at: at)
        for project: ProjectID in ["p", "q"] {
            for n in 0..<30 {
                let card = TaskCard(id: TaskID(rawValue: "\(project)-\(n)"), projectId: project, title: "T", stageId: "queue", state: .queued(nil), hasAcceptanceCriteria: true, updatedAt: at)
                _ = try store.createTask(card: card, body: "", commandId: UUID(), at: at)
            }
        }
        var choices: [ProjectID] = []
        for n in 0..<24 {
            let current = n == 12 ? try KabanStore(path: url.path) : store
            choices.append(try XCTUnwrap(tick(current).transitions.first?.task.card.projectId))
        }
        XCTAssertEqual(choices.filter { $0 == "p" }.count, 18)
        XCTAssertEqual(choices.filter { $0 == "q" }.count, 6)
        let id = UUID()
        _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 1, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: id, at: at)
        XCTAssertThrowsError(try store.setSettings(GlobalSettings(maxConcurrentRuns: 9, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: id, at: at))
    }
    func testCancelAndRecoveryPreserveLifecycleEffectsAcrossRepeatedSupersede() throws {
        let (url, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try create(store); _ = try tick(store); _ = try tick(store)
        let stale = try launch(store)
        _ = try store.recover(passId: UUID(), at: at)
        XCTAssertThrowsError(try store.deliverFake(effectId: stale.id, result: .question("late"), at: at))
        _ = try store.apply(.cancel(keepBranch: false), taskId: "t", commandId: UUID(), at: at)
        let items = try store.pendingEffectItems()
        XCTAssertTrue(items.contains { if case .saveWipAndRollback = $0.effect { true } else { false } })
        XCTAssertTrue(items.contains { if case .cleanupClone = $0.effect { true } else { false } })
        try drain(store)
        XCTAssertEqual(try store.getTaskDetail("t").task.state, .cancelled)
        XCTAssertTrue(try store.pendingEffectItems().isEmpty)
    }
    func testConcurrentTicksDoNotExceedGlobalLimit() async throws {
        let (url, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try create(store, id: "a"); _ = try create(store, id: "b")
        _ = try store.apply(.start("intake-a"), taskId: "a", commandId: UUID(), at: at)
        _ = try store.apply(.start("intake-b"), taskId: "b", commandId: UUID(), at: at)
        _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 1, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at)
        let other = try KabanStore(path: url.path)
        let clock = at
        async let a = store.tick(tickId: UUID(), runId: "a-run", at: clock)
        async let b = other.tick(tickId: UUID(), runId: "b-run", at: clock)
        let receipts = try await [a, b]
        XCTAssertEqual(receipts.flatMap(\.transitions).count, 1)
        XCTAssertEqual(try store.getSnapshot().tasks.filter { $0.state.status == .running }.count, 1)
    }

    func testLegacyV1MigrationPreservesExactOutboxAndUnknownDetail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let dbq = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("m1_headless_v1") { db in
            try db.execute(sql: "CREATE TABLE task (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE event (seq INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE command (id TEXT PRIMARY KEY NOT NULL, request BLOB NOT NULL, receipt BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE recovery (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE effect_outbox (id TEXT PRIMARY KEY NOT NULL REFERENCES command(id), task_id TEXT NOT NULL REFERENCES task(id), payload BLOB NOT NULL)")
        }
        try migrator.migrate(dbq)
        let p = try pipeline(); let id = UUID()
        let card = TaskCard(id: "legacy", projectId: "unknown", title: "Legacy", stageId: "queue", state: .queued(nil), updatedAt: at)
        let task = DurableTask(card: card, machine: TaskMachineState(taskId: card.id, stageId: "queue"), pipeline: p)
        let receipt = DurableReceipt(commandId: id, firstSeq: nil, lastSeq: 0, task: task)
        let batch = PendingEffectBatch(version: 1, commandId: id, taskId: card.id, effects: [.killRun("old"), .cleanupClone(keepBranch: true)])
        let bytes = try KabanStore.encode(batch)
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO task VALUES (?, ?)", arguments: [card.id.rawValue, try KabanStore.encode(task)])
            try db.execute(sql: "INSERT INTO command VALUES (?, ?, ?)", arguments: [id.uuidString, Data(), try KabanStore.encode(receipt)])
            try db.execute(sql: "INSERT INTO effect_outbox VALUES (?, ?, ?)", arguments: [id.uuidString, card.id.rawValue, bytes])
        }
        let store = try KabanStore(path: url.path)
        XCTAssertEqual(try store.snapshot().tasks, [task])
        XCTAssertEqual(try store.pendingEffects(), [batch])
        XCTAssertEqual(try store.pendingEffectItems().map(\.effect), batch.effects)
        XCTAssertThrowsError(try store.getSnapshot())
        XCTAssertThrowsError(try store.getTaskDetail(card.id))
        XCTAssertEqual(try dbq.read { try Data.fetchOne($0, sql: "SELECT payload FROM effect_outbox") }, bytes)
        var incompatible = p; incompatible.stages[1].name = "Different generation"
        _ = try store.registerProject(ProjectSummary(id: "unknown", name: "Registered later", path: "/never-read", mascotSeed: "seed"), pipeline: incompatible, commandId: UUID(), at: at)
        XCTAssertThrowsError(try store.getSnapshot()) // task retains its original immutable pipeline
        try store.acknowledgeEffects(commandId: id)
        XCTAssertTrue(try store.pendingEffectItems().isEmpty)
    }
    func testManagedCannotBypassResultAuditAndRunIdentity() throws {
        let (url, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try create(store, id: "a"); _ = try create(store, id: "b")
        _ = try store.apply(.start("intake-a"), taskId: "a", commandId: UUID(), at: at)
        _ = try store.apply(.start("intake-b"), taskId: "b", commandId: UUID(), at: at)
        _ = try store.apply(.start("shared-run"), taskId: "a", commandId: UUID(), at: at)
        XCTAssertThrowsError(try store.apply(.start("shared-run"), taskId: "b", commandId: UUID(), at: at))
        let effect = try launch(store)
        XCTAssertThrowsError(try store.acknowledgeEffects(commandId: effect.commandId))
        XCTAssertThrowsError(try store.deliverFake(effectId: effect.id, result: .acknowledged, at: at))
        XCTAssertTrue(try store.pendingEffectItems().contains(effect))
        XCTAssertTrue(try store.getSnapshot().pipelines.first?.issues.contains { $0.code == "merge_count" } == true)
        let unknown = PendingEffectBatch(version: 1, commandId: UUID(), taskId: "a", effects: [.raiseRateLimit])
        let future = PendingEffectBatch(version: 99, commandId: UUID(), taskId: "a", effects: [.killRun("shared-run")])
        try store.database.write { db in try KabanStore.enqueue(unknown, db: db); try KabanStore.enqueue(future, db: db) }
        for pending in try store.pendingEffectItems() where pending.commandId == unknown.commandId || pending.commandId == future.commandId {
            XCTAssertThrowsError(try FakeDriver.result(for: pending, agent: .question("Q")))
            XCTAssertThrowsError(try store.deliverFake(effectId: pending.id, result: .acknowledged, at: at))
            XCTAssertTrue(try store.pendingEffectItems().contains(pending))
        }
    }

    func testAnsweredPriorityHumanWIPAndProjectRunLimit() throws {
        let (url, store, pipeline) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try store.registerProject(ProjectSummary(id: "p", name: "P", path: "/never-read", maxRuns: 1, mascotSeed: "seed"), pipeline: pipeline, commandId: UUID(), at: at)
        _ = try create(store, id: "first"); _ = try tick(store); _ = try tick(store)
        let effect = try launch(store)
        _ = try store.deliverFake(effectId: effect.id, result: .question("Question"), at: at)
        let request = try XCTUnwrap(store.getTaskDetail("first").humanRequests.first?.requestId)
        _ = try store.apply(.answer(text: "Answer", requestId: request), taskId: "first", commandId: UUID(), at: at)
        _ = try create(store, id: "new", priority: 100)
        XCTAssertEqual(try tick(store).transitions.first?.task.card.id, "first")
        _ = try store.apply(.start("new-intake"), taskId: "new", commandId: UUID(), at: at)
        XCTAssertTrue(try tick(store).transitions.isEmpty) // maxRuns=1, despite global=2
        _ = try store.deliverFake(effectId: launch(store).id, result: .completed(summary: "First"), at: at); try drain(store)
        _ = try store.apply(.start("review-first"), taskId: "first", commandId: UUID(), at: at)
        _ = try store.apply(.pause, taskId: "first", commandId: UUID(), at: at)
        _ = try store.apply(.start("run-new"), taskId: "new", commandId: UUID(), at: at)
        _ = try store.deliverFake(effectId: launch(store).id, result: .completed(summary: "New"), at: at); try drain(store)
        XCTAssertTrue(try tick(store).transitions.isEmpty) // paused admitted review still owns slot
        XCTAssertEqual(try store.getTaskDetail("new").task.state, .queued(nil))
        _ = try store.apply(.resume, taskId: "first", commandId: UUID(), at: at)
        _ = try store.apply(.approve, taskId: "first", commandId: UUID(), at: at)
        XCTAssertEqual(try tick(store).transitions.first?.task.card.id, "new")
    }

    func testSnapshotThenEventsMatchesFreshSnapshotThroughHumanFlow() throws {
        let (url, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let initial = try store.getSnapshot()
        var projection = BoardProjection(snapshot: initial)
        _ = try create(store); _ = try tick(store); _ = try tick(store)
        _ = try store.deliverFake(effectId: launch(store).id, result: .question("Choose"), at: at)
        let request = try XCTUnwrap(store.getTaskDetail("t").humanRequests.first?.requestId)
        _ = try store.apply(.answer(text: "A", requestId: request), taskId: "t", commandId: UUID(), at: at)
        _ = try tick(store)
        _ = try store.deliverFake(effectId: launch(store).id, result: .completed(summary: "Done"), at: at); try drain(store)
        _ = try tick(store)
        _ = try store.apply(.approve, taskId: "t", commandId: UUID(), at: at); try drain(store)
        _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 3, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at)
        for event in try store.events(after: initial.seq) {
            let outcome = projection.apply(event)
            XCTAssertTrue(outcome == .applied || outcome == .ignored)
        }
        let fresh = try store.getSnapshot()
        XCTAssertEqual(projection.stateSeq, fresh.seq)
        XCTAssertFalse(projection.needsResync)
        XCTAssertEqual(projection.tasks, Dictionary(uniqueKeysWithValues: fresh.tasks.map { ($0.id, $0) }))
        XCTAssertEqual(projection.projects, Dictionary(uniqueKeysWithValues: fresh.projects.map { ($0.id, $0) }))
        XCTAssertEqual(projection.pipelines, Dictionary(uniqueKeysWithValues: fresh.pipelines.map { ($0.projectId, $0) }))
        let settingsEvents = try store.events(after: initial.seq).compactMap { event -> GlobalSettings? in
            if case .settingsChanged(let change) = event.event { return change.settings }
            return nil
        }
        XCTAssertEqual(settingsEvents.last, fresh.settings)
        XCTAssertEqual(projection.openIncidentCount, fresh.openIncidentCount)
        XCTAssertEqual(projection.stageLoad, BoardProjection(snapshot: fresh).stageLoad)
    }

    func testPausedOldGateResultCannotAdvanceResumedInvocation() throws {
        let (url, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try create(store); _ = try tick(store); _ = try tick(store)
        _ = try store.deliverFake(effectId: launch(store).id, result: .completed(summary: "Old"), at: at)
        let old = try XCTUnwrap(store.pendingEffectItems().first { if case .runGates = $0.effect { true } else { false } })
        _ = try store.apply(.pause, taskId: "t", commandId: UUID(), at: at)
        _ = try store.apply(.resume, taskId: "t", commandId: UUID(), at: at); _ = try tick(store)
        _ = try store.deliverFake(effectId: launch(store).id, result: .completed(summary: "New"), at: at)
        let before = try store.getTaskDetail("t")
        XCTAssertThrowsError(try store.deliverFake(effectId: old.id, result: .gatesPassed, at: at))
        XCTAssertEqual(try store.getTaskDetail("t"), before)
        try drain(store)
        XCTAssertEqual(try store.getTaskDetail("t").task.stageId, "review")
    }

}
