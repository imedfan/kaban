import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class LiveBoardPresentationTests: XCTestCase {
    func testSameStageIDInDifferentPipelinesCannotDefineCompactGroup() {
        let agent = Fix.stage("review", .agent, order: 0)
        let human = Fix.stage("review", .human, order: 0)
        let card = Fix.card("t", stage: "review", state: .running)
        XCTAssertEqual(BoardKindGroup.group(card: card, stage: agent), .agent)
        XCTAssertEqual(BoardKindGroup.group(card: card, stage: human), .waitingHuman)
        var review = card; review.state = .waitingHuman(.review)
        for kind in StageKind.allCases {
            XCTAssertEqual(BoardKindGroup.group(card: review, stage: Fix.stage("review", kind, order: 0)), .waitingHuman)
        }
        XCTAssertNotEqual(BoardStageKey(projectID: Fix.project, stageID: "review"), BoardStageKey(projectID: Fix.other, stageID: "review"))
    }
    func testWIPShrinkUsesServerLoadAndKeepsCardsIncludingHiddenStage() {
        var stage = Fix.stage("dev", .agent, order: 4); stage.display.hidden = true; stage.display.collapsed = true
        let tasks = (0..<4).map { Fix.card("t\($0)", state: .running) }
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 10, tasks: tasks, pipelines: [Fix.pipeline([stage])]))
        XCTAssertNil(projection.load(projectId: Fix.project, stageId: "dev"))
        let load = StageLoad(projectId: Fix.project, stageId: "dev", wipUsed: 4, wipLimit: 2)
        XCTAssertEqual(projection.apply(Fix.envelope(11, .stageLoadChanged(load))), .applied)
        XCTAssertEqual(StageLoadPresentation(load: projection.load(projectId: Fix.project, stageId: "dev")!).label, "4/2")
        XCTAssertTrue(StageLoadPresentation(load: load).exceeded)
        XCTAssertEqual(projection.lanes()[0].columns[0].taskIds, tasks.map(\.id))
        XCTAssertEqual(projection.lanes()[0].columns[0].stage.display, stage.display)
        XCTAssertEqual(projection.tasks.count, 4)
    }
    func testEveryReasonHasDistinctTextAndNonChargingRetriesHaveNoTimer() {
        let retryLabels = RetryWaitReason.allCases.map { CardPresentation(state: .retryWait($0)).label }
        XCTAssertEqual(Set(retryLabels).count, RetryWaitReason.allCases.count)
        let waitingLabels = WaitingHumanReason.allCases.map { CardPresentation(state: .waitingHuman($0)).label }
        XCTAssertEqual(Set(waitingLabels).count, WaitingHumanReason.allCases.count)
        XCTAssertEqual(CardPresentation(state: .queued(.quotaCm)).label, "Ждёт квоту Cm")
        XCTAssertEqual(CardPresentation(state: .queued(.quotaOm)).label, "Ждёт квоту Om")
        for reason in RetryWaitReason.allCases {
            var card = Fix.card("t", state: .retryWait(reason)); card.retryAt = Fix.t0.addingTimeInterval(90)
            XCTAssertEqual(CardPresentation.retryCountdown(card: card, now: Fix.t0) != nil, reason.chargesAttempt)
        }
        var card = Fix.card("t", state: .retryWait(.crash))
        XCTAssertNil(CardPresentation.retryCountdown(card: card, now: Fix.t0))
        card.retryAt = Fix.t0.addingTimeInterval(90)
        XCTAssertEqual(CardPresentation.retryCountdown(card: card, now: Fix.t0), "Повтор через 1:30")
    }
    func testReservationAndOldProgressDoNotClaimActiveProcess() {
        let card = Fix.card("t", state: .running)
        let run = RunSummary(id: "new", taskId: card.id, stageId: card.stageId, number: 2, status: .running, requestedModel: "model", startedAt: Fix.t0)
        let report = RunProgress(runId: "old", taskId: card.id, message: "old run", lastActivityAt: Fix.t0)
        XCTAssertNil(CardPresentation.progress(card: card, currentRun: run, reports: [report.runId: report]))
        XCTAssertEqual(CardPresentation(card: card).label, "Запуск зарезервирован")
        var current = report; current.runId = run.id
        XCTAssertEqual(CardPresentation.progress(card: card, currentRun: run, reports: [run.id: current]), current)
        var ended = run; ended.endedAt = Fix.t0
        XCTAssertNil(CardPresentation.progress(card: card, currentRun: ended, reports: [run.id: current]))
        var moved = card; moved.stageId = "test"
        XCTAssertNil(CardPresentation.progress(card: moved, currentRun: run, reports: [run.id: current]))
        var gating = card; gating.state = .gating
        XCTAssertNil(CardPresentation.progress(card: gating, currentRun: run, reports: [run.id: current]))
    }
    func testBadgePriorityAndNoInventedCounters() {
        var card = Fix.card("t", hasAcceptanceCriteria: false)
        card.unusedGitGrants = 2; card.bounceByReason = ["test_dev": 3]; card.overlapsWith = ["other"]
        card.model = "model"
        let badges = CardPresentation.badges(card: card, pipeline: Fix.pipeline())
        XCTAssertEqual(badges.map(\.symbol), ["key", "arrow.uturn.backward", "square.on.square", "cpu", "checklist"])
        XCTAssertTrue(badges[1].label.contains("test → dev"))
        XCTAssertTrue(badges[2].help.contains("other"))
        XCTAssertEqual(badges.count, 5)
        let empty = Fix.card("empty", hasAcceptanceCriteria: true)
        XCTAssertTrue(CardPresentation.badges(card: empty, pipeline: nil).isEmpty)
    }
    func testAmbiguousLegacyBounceKeyDoesNotInventStagePair() {
        let stages = [Fix.stage("a_b", .agent, order: 0), Fix.stage("c", .agent, order: 1),
                      Fix.stage("a", .agent, order: 2), Fix.stage("b_c", .agent, order: 3)]
        var card = Fix.card("bounce", hasAcceptanceCriteria: true)
        card.bounceByReason = ["a_b_c": 2]
        XCTAssertEqual(CardPresentation.badges(card: card, pipeline: Fix.pipeline(stages)).first?.label, "a_b_c · 2")
    }
    func testLimitQualifierUsesExactServerRuleAndKeepsMissingTotalUnknown() {
        var merge = Fix.stage("merge", .merge, order: 1)
        merge.onConflict = .init(stage: "dev", limit: 2)
        let pipeline = Fix.pipeline([merge])
        var card = Fix.card("limit", stage: "merge", state: .waitingHuman(.conflictLimit))
        card.bounceByReason = ["merge_conflict": 2]
        XCTAssertEqual(LimitReasonText(card: card, pipeline: pipeline).qualifier, "при конфликте, 2 из 2")
        XCTAssertNil(LimitReasonText(card: card, pipeline: nil).qualifier)
        card.state = .waitingHuman(.bounceLimit)
        XCTAssertNil(LimitReasonText(card: card, pipeline: pipeline).qualifier)
        card.state = .waitingHuman(.runLimit); card.runsSinceHuman = 12
        XCTAssertEqual(LimitReasonText(card: card, pipeline: pipeline).qualifier, "12 из 12")
    }
    @MainActor func testLocalHideReorderRestartsAndStillReceivesHiddenProjectEvents() async throws {
        let storage = MemoryKeyValueStore()
        let hiddenTask = Fix.card("hidden", project: Fix.other)
        let base = MockKabanClient(snapshot: Fix.snapshot(tasks: [hiddenTask, Fix.card("waiting", state: .waitingHuman(.review), project: Fix.other)], projects: [Fix.project(), Fix.project(Fix.other, openIncidentCount: 2)], pipelines: [Fix.pipeline(), Fix.pipeline(project: Fix.other)]))
        let client = BoardRecordingClient(base)
        let session = BoardSession(client: client, storage: storage, key: "board-test")
        let owner = Task { await session.run() }; defer { owner.cancel() }
        for _ in 0..<300 { if session.canSend { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(session.canSend)
        session.move(Fix.other, to: 0); session.hide(Fix.project)
        XCTAssertEqual(session.visibleIDs, [Fix.other])
        session.hide(Fix.other)
        XCTAssertTrue(client.commands.isEmpty)
        XCTAssertEqual(session.projection?.badgeCounts(for: Fix.other), .init(waitingHuman: 1, openIncidents: 2))
        // Mock emits through its real all-project subscription, independently of BoardSet.
        _ = try await base.send(.init(command: .editTask(taskId: hiddenTask.id, title: "Обновлён скрытый проект", body: nil)))
        for _ in 0..<300 {
            if session.projection?.tasks[hiddenTask.id]?.title == "Обновлён скрытый проект" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.projection?.tasks[hiddenTask.id]?.title, "Обновлён скрытый проект")
        let restored = BoardSetStore(storage: storage); restored.bootstrap(projects: try await base.getSnapshot().projects.map(\.id))
        XCTAssertTrue(restored.visibleProjectIds.isEmpty)
        session.show(Fix.other, at: 0); session.show(Fix.project, at: 0)
        session.move(Fix.other, to: 0)
        let ordered = BoardSetStore(storage: storage); ordered.bootstrap(projects: try await base.getSnapshot().projects.map(\.id))
        XCTAssertEqual(ordered.visibleProjectIds, [Fix.other, Fix.project])
        XCTAssertTrue(client.commands.isEmpty, "No pause/remove commands for local visibility or order")
        owner.cancel(); await owner.value
    }
    @MainActor func testMascotUsesCorrelatedProjectUpdateAndIdempotentCommand() async throws {
        let base = MockKabanClient(snapshot: Fix.snapshot())
        let envelope = CommandEnvelope(command: .setMascot(projectId: Fix.project, seed: "chosen"))
        let reply = try await base.send(envelope)
        XCTAssertEqual(reply.result, .ok)
        XCTAssertNotNil(reply.seq)
        let repeatReply = try await base.send(envelope)
        XCTAssertEqual(repeatReply, reply)
        let snapshot = try await base.getSnapshot()
        XCTAssertEqual(snapshot.projects.first?.mascotSeed, "chosen")
        XCTAssertEqual(snapshot.seq, reply.seq)
    }
}

@MainActor private final class BoardRecordingClient: KabanClient {
    let base: MockKabanClient
    var commands: [CommandEnvelope] = []
    init(_ base: MockKabanClient) { self.base = base }
    func getSnapshot() async throws -> Snapshot { try await base.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await base.synchronize() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { base.updates() }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func capabilities() async throws -> DaemonCapabilities { try await base.capabilities() }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply { commands.append(envelope); return try await base.send(envelope) }
}
