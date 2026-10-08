import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
import KabanBoardCore
@testable import KabanDaemonCore

final class WireCommandTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 123)
    let body = "# Задача 🐗\n\nСохранить **Markdown** буквально.\n\n## Критерии приёмки\n- [ ] Работает\n"

    func fixture(settings: Bool = true) throws -> (URL, KabanStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        let pipeline = try ManagedEngineFixture.pipeline()
        _ = try store.registerProject(ProjectSummary(id: "p", name: "P", path: "/never-read", mascotSeed: "p"), pipeline: pipeline, commandId: UUID(), at: at)
        if settings { _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 2, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at) }
        return (root, store)
    }
    @discardableResult func send(_ command: Command, to store: KabanStore, commandId: CommandID = UUID()) throws -> CommandReply {
        try store.execute(CommandEnvelope(commandId: commandId, command: command), now: { at })
    }
    @discardableResult func create(_ id: TaskID, in store: KabanStore, body: String? = nil) throws -> CommandReply {
        try store.execute(CommandEnvelope(command: .createTask(projectId: "p", title: "Task", body: body ?? self.body)), now: { at }, makeTaskID: { id })
    }
    func errorCode(_ reply: CommandReply) -> String? {
        if case .error(let error) = reply.result { return error.code }
        XCTFail("Expected refusal, received \(reply)"); return nil
    }
    func tick(_ store: KabanStore) throws -> TickReceipt { try store.tick(tickId: UUID(), runId: RunID(rawValue: UUID().uuidString), at: at) }
    func start(_ id: TaskID, in store: KabanStore) throws -> PendingEffect {
        _ = try store.apply(.start(RunID(rawValue: "intake-\(id.rawValue)")), taskId: id, commandId: UUID(), at: at)
        _ = try store.apply(.start(RunID(rawValue: "run-\(id.rawValue)")), taskId: id, commandId: UUID(), at: at)
        return try XCTUnwrap(store.pendingEffectItems().first { effect in
            effect.taskId == id && { if case .startAgentRun = effect.effect { true } else { false } }()
        })
    }
    func review(_ id: TaskID, in store: KabanStore) throws {
        let launch = try start(id, in: store)
        _ = try store.deliverFake(effectId: launch.id, result: .completed(summary: "Done"), at: at)
        try ManagedEngineFixture.drain(store, at: at)
        _ = try store.apply(.start(RunID(rawValue: "review-\(id.rawValue)")), taskId: id, commandId: UUID(), at: at)
    }

    func testWireCreateReplayBeforeIDAndClockAndAfterReopen() throws {
        let (root, store) = try fixture()
        let envelope = CommandEnvelope(command: .createTask(projectId: "p", title: "  Unicode 🐗  ", body: body))
        let decoded = try KabanCoding.makeDecoder().decode(CommandEnvelope.self, from: KabanCoding.makeEncoder().encode(envelope))
        var clocks = 0, ids = 0
        let reply = try store.execute(decoded, now: { clocks += 1; return at }, makeTaskID: { ids += 1; return "t" })
        XCTAssertEqual(reply.result, .taskCreated("t")); XCTAssertEqual(clocks, 1); XCTAssertEqual(ids, 1)
        XCTAssertEqual(try store.getTaskDetail("t").body, body)
        XCTAssertEqual(try store.getTaskDetail("t").task.title, "Unicode 🐗")
        XCTAssertTrue(try store.getTaskDetail("t").task.hasAcceptanceCriteria)
        let reopened = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        _ = try send(.editTask(taskId: "t", title: "Changed later", body: nil), to: reopened)
        let seq = try reopened.getSnapshot().seq
        XCTAssertEqual(try reopened.execute(envelope, now: { XCTFail("Replay must not read clock"); return Date() }, makeTaskID: { XCTFail("Replay must not allocate ID"); return "duplicate" }), reply)
        XCTAssertEqual(try reopened.getSnapshot().seq, seq)
        XCTAssertEqual(try reopened.getSnapshot().tasks.count, 1)
        let events = try reopened.events().filter { $0.commandId == envelope.commandId }
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.seq, reply.seq)
    }

    func testRawRequestConflictAndSharedIdentityWithInternalAPIs() throws {
        let (_, store) = try fixture()
        let id = UUID()
        _ = try send(.createTask(projectId: "p", title: "Task", body: body), to: store, commandId: id)
        let before = try store.getSnapshot()
        let conflict = try store.execute(CommandEnvelope(commandId: id, command: .createTask(projectId: "p", title: " Task ", body: body)), now: { XCTFail("Conflict read clock"); return at }, makeTaskID: { XCTFail("Conflict allocated ID"); return "bad" })
        XCTAssertEqual(errorCode(conflict), "command_id_conflict")
        XCTAssertEqual(try store.getSnapshot(), before)
        XCTAssertThrowsError(try store.setSettings(GlobalSettings(maxConcurrentRuns: 4, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: id, at: at)) { XCTAssertEqual($0 as? StoreError, .commandIdConflict) }
        let internalId = UUID()
        _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 2, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: internalId, at: at)
        XCTAssertEqual(errorCode(try send(.pauseAll, to: store, commandId: internalId)), "command_id_conflict")
        XCTAssertFalse(try store.getSnapshot().schedulerFlags.contains(.macPaused))
    }

    func testDurableRefusalCannotBecomeAppliedWhenStateChanges() throws {
        let (root, store) = try fixture()
        let missing = CommandEnvelope(command: .pauseTask(taskId: "later"))
        let refusal = try store.execute(missing)
        XCTAssertEqual(errorCode(refusal), "not_found"); XCTAssertNil(refusal.seq)
        _ = try create("later", in: store)
        let reopened = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        let before = try reopened.getSnapshot()
        XCTAssertEqual(try reopened.execute(missing, now: { XCTFail("Refusal replay read clock"); return at }), refusal)
        XCTAssertEqual(try reopened.getSnapshot(), before)
        XCTAssertEqual(try send(.pauseTask(taskId: "later"), to: reopened).result, .ok)
        XCTAssertEqual(errorCode(try send(.checkEnvironment, to: reopened)), "unsupported_command")
        var incompatible = CommandEnvelope(command: .pauseAll); incompatible.protocolVersion += 1
        XCTAssertEqual(errorCode(try reopened.execute(incompatible)), CommandError.protocolMismatchCode)
        incompatible.protocolVersion = KabanCoding.protocolVersion
        XCTAssertEqual(try reopened.execute(incompatible).result, .ok)
    }

    func testEditStateBodyValidationAndFreshQueries() throws {
        let (_, store) = try fixture()
        _ = try create("t", in: store)
        let query = CommandEnvelope(command: .getTaskDetail(taskId: "t"))
        let initial = try store.execute(query)
        _ = try send(.editTask(taskId: "t", title: "Title only", body: nil), to: store)
        XCTAssertEqual(try store.getTaskDetail("t").body, body)
        let fresh = try store.execute(query)
        XCTAssertNotEqual(initial, fresh); XCTAssertNil(fresh.seq)
        let pending = try start("t", in: store)
        let edit = CommandEnvelope(command: .editTask(taskId: "t", title: "Blocked", body: ""))
        let refusal = try store.execute(edit)
        XCTAssertEqual(errorCode(refusal), CommandError.invalidStateCode)
        _ = try send(.pauseTask(taskId: "t"), to: store)
        XCTAssertEqual(try store.execute(edit), refusal)
        XCTAssertEqual(try send(.editTask(taskId: "t", title: nil, body: ""), to: store).result, .ok)
        XCTAssertEqual(try store.getTaskDetail("t").body, ""); XCTAssertFalse(try store.getTaskDetail("t").task.hasAcceptanceCriteria)
        XCTAssertEqual(errorCode(try send(.editTask(taskId: "t", title: nil, body: nil), to: store)), "invalid_request")
        XCTAssertEqual(errorCode(try send(.editTask(taskId: "t", title: " \n ", body: nil), to: store)), "invalid_request")
        XCTAssertEqual(errorCode(try send(.editTask(taskId: "t", title: "Atomic", body: "\0"), to: store)), "invalid_request")
        XCTAssertEqual(try store.getTaskDetail("t").task.title, "Title only")
        XCTAssertThrowsError(try store.deliverFake(effectId: pending.id, result: .completed(summary: "stale"), at: at)) { XCTAssertEqual($0 as? StoreError, .effectSuperseded) }
        XCTAssertEqual(try send(.getRunHistory(taskId: "t"), to: store).result, .runs(try store.getTaskDetail("t").runs))
    }

    func testUnknownBodyIsNotOverwrittenButTitleCanChange() throws {
        let (_, store) = try fixture()
        _ = try create("t", in: store)
        try store.database.write { db in
            var detail = try KabanStore.detail("t", db: db); detail.body = nil
            try KabanStore.saveDetail(detail, taskId: "t", db: db)
        }
        XCTAssertEqual(errorCode(try send(.editTask(taskId: "t", title: "Atomic", body: ""), to: store)), "incomplete_projection")
        XCTAssertEqual(try store.getTaskDetail("t").task.title, "Task"); XCTAssertNil(try store.getTaskDetail("t").body)
        XCTAssertEqual(try send(.editTask(taskId: "t", title: "Known title", body: nil), to: store).result, .ok)
        XCTAssertNil(try store.getTaskDetail("t").body)
    }

    func testAcceptanceCriteriaAndAuthoritativeMoveSlotValidation() throws {
        let (_, store) = try fixture()
        _ = try create("t", in: store, body: "Описание без критериев")
        XCTAssertTrue(try tick(store).transitions.isEmpty)
        XCTAssertEqual(errorCode(try send(.moveTask(taskId: "t", stage: "agent"), to: store)), CommandError.invalidStateCode)
        _ = try send(.editTask(taskId: "t", title: nil, body: body), to: store)
        _ = try send(.pauseProject(projectId: "p"), to: store)
        XCTAssertEqual(errorCode(try send(.moveTask(taskId: "t", stage: "agent"), to: store)), "scheduler_blocked")
        _ = try send(.resumeProject(projectId: "p"), to: store)
        _ = try create("a", in: store); _ = try start("a", in: store)
        _ = try create("b", in: store); _ = try start("b", in: store)
        XCTAssertEqual(errorCode(try send(.moveTask(taskId: "t", stage: "agent"), to: store)), "scheduler_blocked")
        _ = try send(.pauseTask(taskId: "a"), to: store)
        XCTAssertEqual(try send(.moveTask(taskId: "t", stage: "agent"), to: store).result, .ok)
        XCTAssertEqual(try store.getTaskDetail("t").task.stageId, "agent")
        XCTAssertEqual(errorCode(try send(.moveTask(taskId: "t", stage: "review"), to: store)), CommandError.invalidStateCode)
        XCTAssertEqual(errorCode(try send(.moveTask(taskId: "t", stage: "done"), to: store)), CommandError.invalidStateCode)
        XCTAssertEqual(errorCode(try send(.moveTask(taskId: "t", stage: "agent"), to: store)), CommandError.invalidStateCode)
    }

    func testMoveAndCancelSupersedeOldLaunchAndPreserveExactLifecycleEffects() throws {
        let (_, store) = try fixture()
        _ = try create("t", in: store); let launch = try start("t", in: store)
        let moved = try send(.moveTask(taskId: "t", stage: "queue"), to: store)
        XCTAssertEqual(moved.result, .ok)
        let detail = try store.getTaskDetail("t")
        XCTAssertEqual(detail.task.state, .queued(nil)); XCTAssertEqual(detail.task.runsSinceHuman, 0)
        XCTAssertEqual(detail.runs.first?.endReason, .movedByHuman); XCTAssertEqual(detail.runs.first?.countsTowardLimits, false)
        XCTAssertEqual(try store.getSnapshot().stageLoad.first { $0.stageId == "agent" }?.wipUsed, 0)
        XCTAssertThrowsError(try store.deliverFake(effectId: launch.id, result: .question("obsolete"), at: at))
        let items = try store.pendingEffectItems()
        XCTAssertTrue(items.contains { $0.effect == .killRun("run-t") })
        let cancel = CommandEnvelope(command: .cancelTask(taskId: "t", keepBranch: true))
        let reply = try store.execute(cancel, now: { at })
        let effects = try store.pendingEffectItems()
        XCTAssertTrue(effects.contains { $0.effect == .cleanupClone(keepBranch: true) })
        XCTAssertEqual(try store.execute(cancel), reply); XCTAssertEqual(try store.pendingEffectItems(), effects)
        XCTAssertEqual(errorCode(try send(.resumeTask(taskId: "t"), to: store)), CommandError.invalidStateCode)
    }

    func testProjectAndGlobalPausesAreDurableAndDoNotInterruptRuns() throws {
        let (root, store) = try fixture()
        _ = try create("t", in: store); let launch = try start("t", in: store)
        let before = try store.getTaskDetail("t")
        _ = try send(.pauseProject(projectId: "p"), to: store)
        _ = try send(.pauseAll, to: store)
        _ = try create("queued", in: store)
        XCTAssertEqual(try store.getTaskDetail("t").task, before.task)
        XCTAssertTrue(try store.pendingEffectItems().contains(launch))
        let reopened = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        XCTAssertEqual(try reopened.getSnapshot().schedulerFlags, [.macPaused, .projectPaused("p")])
        XCTAssertTrue(try tick(reopened).transitions.isEmpty)
        _ = try reopened.deliverFake(effectId: launch.id, result: .completed(summary: "Allowed while paused"), at: at)
        try ManagedEngineFixture.drain(reopened, at: at)
        XCTAssertEqual(try reopened.getTaskDetail("t").task.stageId, "review")
        XCTAssertTrue(try tick(reopened).transitions.isEmpty)
        _ = try send(.resumeAll, to: reopened)
        XCTAssertTrue(try tick(reopened).transitions.isEmpty)
        _ = try send(.resumeProject(projectId: "p"), to: reopened)
        XCTAssertFalse(try tick(reopened).transitions.isEmpty)
        let resume = try send(.resumeProject(projectId: "p"), to: reopened)
        XCTAssertNotNil(resume.seq)
        XCTAssertEqual(try reopened.events().last?.commandId, resume.commandId)
    }

    func testQuestionAnswerAndHumanReviewReleaseAdmission() throws {
        let (_, store) = try fixture()
        _ = try create("t", in: store); let launch = try start("t", in: store)
        _ = try store.deliverFake(effectId: launch.id, result: .question("Which?"), at: at)
        let request = try XCTUnwrap(store.getTaskDetail("t").humanRequests.first?.requestId)
        let before = try store.getTaskDetail("t")
        XCTAssertEqual(errorCode(try send(.answerHuman(taskId: "t", text: "wrong", requestId: "foreign"), to: store)), CommandError.invalidStateCode)
        XCTAssertEqual(try store.getTaskDetail("t"), before)
        let answer = CommandEnvelope(command: .answerHuman(taskId: "t", text: "Yes", requestId: request))
        let reply = try store.execute(answer, now: { at })
        XCTAssertEqual(try store.execute(answer), reply)
        XCTAssertEqual(try store.getTaskDetail("t").feed.filter { $0.kind == "answer" }.count, 1)
        _ = try tick(store)
        let current = try XCTUnwrap(store.pendingEffectItems().first { if case .startAgentRun = $0.effect { true } else { false } })
        _ = try store.deliverFake(effectId: current.id, result: .completed(summary: "Done"), at: at)
        try ManagedEngineFixture.drain(store, at: at); _ = try tick(store)
        XCTAssertEqual(try store.getSnapshot().stageLoad.first { $0.stageId == "review" }?.wipUsed, 1)
        _ = try send(.pauseTask(taskId: "t"), to: store)
        XCTAssertEqual(try store.getSnapshot().stageLoad.first { $0.stageId == "review" }?.wipUsed, 1)
        _ = try send(.resumeTask(taskId: "t"), to: store)
        XCTAssertEqual(try store.getTaskDetail("t").task.state, .waitingHuman(.review))
        XCTAssertEqual(errorCode(try send(.answerHuman(taskId: "t", text: "No", requestId: nil), to: store)), CommandError.invalidStateCode)
        _ = try send(.requestChanges(taskId: "t", comments: "Fix", target: "agent"), to: store)
        XCTAssertEqual(try store.getSnapshot().stageLoad.first { $0.stageId == "review" }?.wipUsed, 0)
        XCTAssertEqual(try store.snapshot().tasks.first?.machine.pendingPrompt, [.humanComments("Fix")])
    }

    func testReviewCommentIsAtomicIdempotentRedactedAndDurableAfterRetention() throws {
        let (root, store) = try fixture()
        _ = try create("review-note", in: store); try review("review-note", in: store)
        let text = "Check status first  \r\n👋"
        let envelope = CommandEnvelope(command: .requestChanges(taskId: "review-note", comments: text, target: "agent"))
        let first = try store.execute(envelope, now: { at })
        XCTAssertEqual(first.result, .ok)
        let detail = try store.getTaskDetail("review-note")
        XCTAssertEqual(detail.task.stageId, "agent"); XCTAssertEqual(detail.task.state, .queued(nil))
        XCTAssertEqual(detail.feed.filter { $0.kind == "review_comment" }.map(\.text), [text])
        XCTAssertTrue(detail.humanRequests.isEmpty)
        XCTAssertFalse(try store.events(after: 0).contains { if case .humanAnswered = $0.event { true } else { false } })
        XCTAssertEqual(try store.execute(envelope), first)
        XCTAssertEqual(errorCode(try send(.requestChanges(taskId: "review-note", comments: "Refused", target: "agent"), to: store)), CommandError.invalidStateCode)
        XCTAssertEqual(try store.getTaskDetail("review-note"), detail)
        try store.discardJournal()
        let reopened = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        XCTAssertEqual(try reopened.getTaskDetail("review-note").feed.filter { $0.kind == "review_comment" }.map(\.text), [text])
        XCTAssertEqual(try reopened.execute(envelope), first)
        _ = try create("redacted-note", in: reopened); try review("redacted-note", in: reopened)
        _ = try send(.requestChanges(taskId: "redacted-note", comments: "Check sk-abcdefgh1234 safely", target: "agent"), to: reopened)
        let redacted = try XCTUnwrap(reopened.getTaskDetail("redacted-note").feed.first { $0.kind == "review_comment" })
        XCTAssertEqual(redacted.text, "Check <redacted> safely")
    }

    func testApproveRejectAndRetryCommandsUseReducer() throws {
        let (_, store) = try fixture()
        _ = try create("approve", in: store); try review("approve", in: store)
        XCTAssertEqual(try send(.approve(taskId: "approve"), to: store).result, .ok)
        XCTAssertEqual(try store.getTaskDetail("approve").task.state, .done)
        _ = try create("reject", in: store); try review("reject", in: store)
        _ = try send(.reject(taskId: "reject", target: .stage(stageId: "agent"), keepBranch: false), to: store)
        XCTAssertEqual(try store.getTaskDetail("reject").task.stageId, "agent")
        _ = try send(.reject(taskId: "reject", target: .cancel, keepBranch: true), to: store)
        XCTAssertEqual(try store.getTaskDetail("reject").task.state, .cancelled)
        _ = try create("retry", in: store); let launch = try start("retry", in: store)
        _ = try store.deliverFake(effectId: launch.id, result: .question("Again?"), at: at)
        XCTAssertEqual(errorCode(try send(.retryStage(taskId: "retry", grantAttempts: -1), to: store)), CommandError.invalidStateCode)
        XCTAssertEqual(errorCode(try send(.retryStage(taskId: "retry", grantAttempts: Int.max), to: store)), CommandError.invalidStateCode)
        _ = try send(.retryStage(taskId: "retry", grantAttempts: 2), to: store)
        XCTAssertEqual(try store.getTaskDetail("retry").task.state, .queued(nil))
        XCTAssertEqual(try store.getTaskDetail("retry").task.maxAttempts, 5)
    }

    func testPriorityAffectsNextSelectionAndEditsPreserveFIFO() throws {
        let (_, store) = try fixture()
        _ = try create("first", in: store); _ = try create("second", in: store)
        _ = try send(.editTask(taskId: "first", title: "Edited later", body: nil), to: store)
        XCTAssertEqual(try tick(store).transitions.first?.task.card.id, "first")
        // Downstream execution drains before another Backlog admission.
        XCTAssertEqual(try tick(store).transitions.first?.task.card.id, "first")
        _ = try create("third", in: store)
        _ = try send(.setPriority(taskId: "third", priority: 10), to: store)
        XCTAssertEqual(try tick(store).transitions.first?.task.card.id, "third")
    }

    func testSettingsConsentProjectMetadataAndUnknownInitialValues() throws {
        let (_, unknown) = try fixture(settings: false)
        XCTAssertEqual(errorCode(try send(.setMaxConcurrentRuns(count: 1), to: unknown)), "incomplete_projection")
        XCTAssertNil(try unknown.getSnapshot().settings)
        let (root, store) = try fixture()
        let original = try store.getSnapshot().settings
        XCTAssertEqual(errorCode(try send(.setMaxConcurrentRuns(count: 0), to: store)), "invalid_request")
        XCTAssertEqual(errorCode(try send(.setQuotaOptions(options: QuotaOptions(enabled: true, consent: false)), to: store)), "invalid_request")
        XCTAssertEqual(errorCode(try send(.setQuotaOptions(options: QuotaOptions(enabled: false, consent: false, thresholdCm: -1)), to: store)), "invalid_request")
        XCTAssertEqual(try store.getSnapshot().settings, original)
        _ = try send(.setMaxConcurrentRuns(count: 1), to: store)
        let options = QuotaOptions(enabled: true, consent: true, pollInterval: 900, thresholdCm: 11, thresholdOm: 22)
        let consent = try send(.setQuotaOptions(options: options), to: store)
        XCTAssertEqual(try store.getSnapshot().settings?.quotaConsentedAt, at)
        _ = try store.execute(CommandEnvelope(command: .setQuotaOptions(options: options)), now: { at.addingTimeInterval(999) })
        XCTAssertEqual(try store.getSnapshot().settings?.quotaConsentedAt, at)
        _ = try send(.setProjectWeight(projectId: "p", weight: 3, maxRuns: 1), to: store)
        _ = try send(.setMascot(projectId: "p", seed: "p#2"), to: store)
        XCTAssertEqual(errorCode(try send(.setProjectIdentity(projectId: "p", identity: GitIdentity(name: "\n", email: "ok")), to: store)), CommandError.identityRequiredCode)
        _ = try send(.setProjectIdentity(projectId: "p", identity: GitIdentity(name: " Artem ", email: " a@example.test ")), to: store)
        let reopened = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        let snapshot = try reopened.getSnapshot()
        XCTAssertEqual(snapshot.settings?.quotaOptions, options); XCTAssertEqual(snapshot.settings?.maxConcurrentRuns, 1)
        XCTAssertNil(snapshot.quota)
        XCTAssertEqual(snapshot.projects.first?.identity, GitIdentity(name: "Artem", email: "a@example.test"))
        XCTAssertEqual(snapshot.projects.first?.weight, 3); XCTAssertEqual(snapshot.projects.first?.maxRuns, 1); XCTAssertEqual(snapshot.projects.first?.mascotSeed, "p#2")
        XCTAssertEqual(try reopened.events().first { $0.seq == consent.seq }?.commandId, consent.commandId)
    }

    func testReceiptFailureRollsBackCreateEditPauseAndOutboxThenAllowsRetry() throws {
        let (root, store) = try fixture()
        _ = try create("t", in: store); _ = try start("t", in: store)
        let inspection = try DatabaseQueue(path: root.appendingPathComponent("store.sqlite").path)
        let commands: [Command] = [.createTask(projectId: "p", title: "New", body: body), .pauseTask(taskId: "t"), .pauseAll, .setMaxConcurrentRuns(count: 1)]
        for command in commands {
            let envelope = CommandEnvelope(command: command)
            let before = try store.getSnapshot(), detail = try store.getTaskDetail("t"), effects = try store.pendingEffectItems()
            try inspection.write { db in try db.execute(sql: "CREATE TRIGGER fail_wire BEFORE INSERT ON wire_command BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END") }
            XCTAssertThrowsError(try store.execute(envelope, now: { at }, makeTaskID: { "new" }))
            XCTAssertEqual(try store.getSnapshot(), before); XCTAssertEqual(try store.getTaskDetail("t"), detail); XCTAssertEqual(try store.pendingEffectItems(), effects)
            try inspection.write { db in try db.execute(sql: "DROP TRIGGER fail_wire") }
            XCTAssertNotNil(try store.execute(envelope, now: { at }, makeTaskID: { "new" }).seq)
        }
        // Edit mutates detail before its event/receipt; it must roll back that write too.
        let edit = CommandEnvelope(command: .editTask(taskId: "t", title: "Edited", body: ""))
        let before = try store.getTaskDetail("t")
        try inspection.write { db in try db.execute(sql: "CREATE TRIGGER fail_wire BEFORE INSERT ON wire_command BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END") }
        XCTAssertThrowsError(try store.execute(edit, now: { at }))
        XCTAssertEqual(try store.getTaskDetail("t"), before)
        try inspection.write { db in try db.execute(sql: "DROP TRIGGER fail_wire") }
        XCTAssertEqual(try store.execute(edit, now: { at }).result, .ok)
        XCTAssertEqual(try store.getTaskDetail("t").body, "")
    }

    func testConcurrentReplayAcrossConnectionsCreatesOneTask() async throws {
        let (root, store) = try fixture()
        let other = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        let envelope = CommandEnvelope(command: .createTask(projectId: "p", title: "Concurrent", body: body))
        async let a = store.execute(envelope)
        async let b = other.execute(envelope)
        let replies = try await [a, b]
        XCTAssertEqual(replies[0], replies[1])
        XCTAssertEqual(try store.getSnapshot().tasks.count, 1)
        XCTAssertEqual(try store.events().filter { $0.commandId == envelope.commandId }.count, 1)
    }

    func testV2UpgradePreservesProjectsDetailsReceiptsAndExactEffects() throws {
        let (root, store) = try fixture()
        let card = TaskCard(id: "legacy-v2", projectId: "p", title: "Stored", stageId: "queue", state: .queued(nil), hasAcceptanceCriteria: true, updatedAt: at)
        let created = try store.createTask(card: card, body: body, commandId: UUID(), at: at)
        _ = try start(card.id, in: store)
        let snapshot = try store.getSnapshot(), detail = try store.getTaskDetail(card.id), effects = try store.pendingEffectItems()
        // v3 is purely additive; remove only its tables/marker to construct the published v2 schema.
        try store.database.write { db in
            try db.execute(sql: "DROP TABLE wire_command")
            try db.execute(sql: "DROP TABLE scheduler_pause")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'm1_wire_v3'")
        }
        let upgraded = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        XCTAssertEqual(try upgraded.getSnapshot(), snapshot); XCTAssertEqual(try upgraded.getTaskDetail(card.id), detail)
        XCTAssertEqual(try upgraded.pendingEffectItems(), effects)
        XCTAssertEqual(try upgraded.createTask(card: card, body: body, commandId: created.commandId, at: Date()), created)
        XCTAssertEqual(try send(.pauseTask(taskId: card.id), to: upgraded).result, .ok)
    }

    func testProjectPauseAllowsOtherProjectAndIntakeFlagsClearThroughJournal() throws {
        let (_, store) = try fixture()
        _ = try store.registerProject(ProjectSummary(id: "q", name: "Q", path: "/never-read", mascotSeed: "q"), pipeline: ManagedEngineFixture.pipeline(), commandId: UUID(), at: at)
        _ = try create("first", in: store); let first = try start("first", in: store)
        _ = try create("second", in: store); let second = try start("second", in: store)
        let initial = try store.getSnapshot()
        var projection = BoardProjection(snapshot: initial)
        _ = try store.deliverFake(effectId: first.id, result: .question("One"), at: at)
        _ = try store.deliverFake(effectId: second.id, result: .question("Two"), at: at)
        XCTAssertTrue(try store.getSnapshot().schedulerFlags.contains(.intakePaused("p")))
        _ = try send(.pauseProject(projectId: "p"), to: store)
        _ = try send(.createTask(projectId: "q", title: "Other project", body: body), to: store)
        XCTAssertEqual(try tick(store).transitions.first?.task.card.projectId, "q")
        _ = try send(.answerHuman(taskId: "first", text: "A", requestId: nil), to: store)
        for event in try store.events(after: initial.seq) { XCTAssertEqual(projection.apply(event), .applied) }
        XCTAssertEqual(projection.ephemeral.schedulerFlags, [.projectPaused("p")])
        XCTAssertEqual(projection.ephemeral.schedulerFlags, try store.getSnapshot().schedulerFlags)
    }

    func testSnapshotPlusJournalMatchesFrontendProjectionIncludingSettingsAndFlags() throws {
        let (_, store) = try fixture()
        let initial = try store.getSnapshot()
        var projection = BoardProjection(snapshot: initial)
        _ = try create("t", in: store)
        let pause = CommandEnvelope(command: .pauseTask(taskId: "t"))
        projection.markSent(commandId: pause.commandId, taskId: "t", at: at)
        let reply = try store.execute(pause, now: { at })
        XCTAssertEqual(reply.result, .ok); XCTAssertTrue(projection.isSent("t"))
        XCTAssertNil(projection.tasks["t"], "Acknowledgement itself must not change the board")
        _ = try send(.resumeTask(taskId: "t"), to: store)
        _ = try send(.editTask(taskId: "t", title: "Edited", body: body), to: store)
        _ = try send(.pauseAll, to: store)
        _ = try send(.setMaxConcurrentRuns(count: 3), to: store)
        _ = try send(.setMascot(projectId: "p", seed: "p#1"), to: store)
        for event in try store.events(after: initial.seq) { XCTAssertEqual(projection.apply(event), .applied) }
        let fresh = try store.getSnapshot()
        XCTAssertFalse(projection.isSent("t")); XCTAssertFalse(projection.needsResync)
        XCTAssertEqual(projection.stateSeq, fresh.seq)
        XCTAssertEqual(projection.tasks, Dictionary(uniqueKeysWithValues: fresh.tasks.map { ($0.id, $0) }))
        XCTAssertEqual(projection.projects, Dictionary(uniqueKeysWithValues: fresh.projects.map { ($0.id, $0) }))
        XCTAssertEqual(projection.settings, fresh.settings); XCTAssertEqual(projection.ephemeral.schedulerFlags, fresh.schedulerFlags)
        XCTAssertEqual(projection.stageLoad, fresh.stageLoad)
        let resume = try send(.resumeAll, to: store)
        for event in try store.events(after: fresh.seq) { XCTAssertEqual(projection.apply(event), .applied) }
        XCTAssertNotNil(resume.seq); XCTAssertEqual(projection.ephemeral.schedulerFlags, [])
    }
}
