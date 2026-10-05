import XCTest
@testable import KabanBoardCore
import KabanProtocol

final class BoardProjectionTests: XCTestCase {
    func testSnapshotBuildsLanesAndColumnsInDisplayOrder() throws {
        let reversed = Array(Fix.baseStages.reversed())
        let task = Fix.card("t-1", stage: "dev", state: .running, title: "Парсер")
        let projection = BoardProjection(snapshot: Fix.snapshot(tasks: [task], pipelines: [Fix.pipeline(reversed)]))
        let lane = try XCTUnwrap(projection.lanes().first)
        XCTAssertEqual(lane.project.id, Fix.project)
        XCTAssertEqual(lane.columns.map(\.stage.id.rawValue), ["backlog", "dev", "gate", "test", "done"])
        XCTAssertEqual(lane.columns.first { $0.stage.id == "dev" }?.taskIds ?? [], ["t-1"])
        XCTAssertEqual(projection.tasks["t-1"]?.title, "Парсер")
    }

    func testCardEventsReplaceTheWholeCard() {
        let old = Fix.card("t-1", stage: "dev", state: .running, title: "Старая", files: [Fix.file(".env.local")])
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [old]))
        let updated = TaskCard(
            id: "t-1", projectId: Fix.project, title: "Новая", stageId: "test", state: .queued(nil),
            priority: 4, branch: "kaban/t-1", attempt: 2, runsSinceHuman: 3,
            suspiciousFiles: [], updatedAt: Fix.t0.addingTimeInterval(5)
        )
        XCTAssertEqual(projection.apply(Fix.envelope(2, .taskUpdated(updated))), .applied)
        XCTAssertEqual(projection.tasks["t-1"], updated)
        XCTAssertEqual(projection.lanes()[0].columns.first { $0.stage.id == "dev" }?.taskIds ?? [], [])
        XCTAssertEqual(projection.lanes()[0].columns.first { $0.stage.id == "test" }?.taskIds ?? [], ["t-1"])

        let edited = TaskCard(
            id: "t-1", projectId: Fix.project, title: "Правленая", stageId: "test", state: .paused, updatedAt: Fix.t0
        )
        XCTAssertEqual(projection.apply(Fix.envelope(3, .taskEdited(edited))), .applied)
        XCTAssertEqual(projection.tasks["t-1"], edited)

        let created = Fix.card("t-2", stage: "backlog", state: .queued(nil), title: "Вторая")
        XCTAssertEqual(projection.apply(Fix.envelope(4, .taskCreated(created))), .applied)
        XCTAssertEqual(projection.tasks["t-2"], created)
        XCTAssertEqual(projection.taskOrder, ["t-1", "t-2"])
    }

    func testTransitionIsAHintAndDoesNotMoveTheCard() {
        let card = Fix.card("t-1", stage: "dev", state: .running)
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [card]))
        let transition = TaskTransition(
            taskId: "t-1", fromStage: "dev", toStage: "test", from: .running, to: .queued(nil), by: .daemon, runId: "r-1"
        )
        XCTAssertEqual(projection.apply(Fix.envelope(2, .taskTransitioned(transition))), .applied)
        XCTAssertEqual(projection.tasks["t-1"], card)
        XCTAssertEqual(projection.transitionHints["t-1"]?.transition, transition)
        XCTAssertEqual(projection.feed.map(\.taskId), ["t-1"])
        XCTAssertEqual(projection.lanes()[0].columns.first { $0.stage.id == "dev" }?.taskIds ?? [], ["t-1"])
    }

    func testDomainEventsGoToTheFeedOnly() {
        let files = [Fix.file(".env.local")]
        let card = Fix.card("t-1", stage: "dev", state: .waitingHuman(.suspiciousFiles), files: files)
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [card], projects: [Fix.project(openIncidentCount: 1)], openIncidents: 1))
        let found = SuspiciousFilesFound(taskId: "t-1", runId: "r-1", stageId: "dev", files: [Fix.file(".env.other", blob: "ffff")])
        let accepted = SuspiciousFilesAccepted(taskId: "t-1", files: files, by: .human, commandId: Fix.command)
        XCTAssertEqual(projection.apply(Fix.envelope(2, .suspiciousFilesFound(found))), .applied)
        XCTAssertEqual(projection.apply(Fix.envelope(3, .suspiciousFilesAccepted(accepted), commandId: Fix.command)), .applied)
        XCTAssertEqual(projection.tasks["t-1"], card, "предметные события не заменяют карточку")
        XCTAssertEqual(projection.feed.count, 2)
        XCTAssertTrue(projection.isSent("t-1") == false)

        projection.markSent(commandId: Fix.command, taskId: "t-1", at: Fix.t0)
        XCTAssertTrue(projection.isSent("t-1"))
        XCTAssertEqual(projection.apply(Fix.envelope(4, .suspiciousFilesAccepted(accepted), commandId: Fix.command)), .applied)
        XCTAssertTrue(projection.isSent("t-1"), "«отправлено» снимает только taskUpdated или ошибка")

        let incident = Incident(
            id: "i-1", projectId: Fix.project, taskId: "t-1", runId: "r-1", kind: .refsMoved, rolledBack: ["refs/heads/main"], openedAt: Fix.t0
        )
        XCTAssertEqual(projection.apply(Fix.envelope(5, .incidentOpened(incident))), .applied)
        XCTAssertEqual(projection.badgeCounts(for: Fix.project), ProjectBadgeCounts(waitingHuman: 1, openIncidents: 1))
        XCTAssertEqual(projection.openIncidentCount, 1)
        XCTAssertEqual(projection.tasks["t-1"]?.state, .waitingHuman(.suspiciousFiles))
    }

    func testUnknownEventIsIgnoredButConsumesSeq() throws {
        let card = Fix.card("t-1")
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 5, tasks: [card]))
        XCTAssertEqual(projection.apply(Fix.envelope(6, .unknown(type: "fromTheFuture"))), .ignored)
        XCTAssertEqual(projection.tasks["t-1"], card)
        XCTAssertTrue(projection.feed.isEmpty)
        XCTAssertEqual(try XCTUnwrap(projection.cursor(for: .all)).lastAppliedSeq, 6)
        let updated = Fix.card("t-1", state: .running, title: "Дальше")
        XCTAssertEqual(projection.apply(Fix.envelope(7, .taskUpdated(updated))), .applied)
        XCTAssertEqual(projection.tasks["t-1"], updated)
    }

    func testProjectAndPipelineEventsUpdateLanes() {
        let removed = StageLoad(projectId: Fix.project, stageId: "old", wipUsed: 0, wipLimit: 2)
        let retained = StageLoad(projectId: Fix.project, stageId: "dev", wipUsed: 1, wipLimit: 2)
        let unrelated = StageLoad(projectId: Fix.other, stageId: "old", wipUsed: 0, wipLimit: 3)
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [Fix.card("t-1")], pipelines: [], stageLoad: [removed, retained, unrelated]))
        XCTAssertEqual(projection.lanes()[0].columns.count, 0)
        let added = Fix.project(Fix.other, name: "site")
        XCTAssertEqual(projection.apply(Fix.envelope(2, .projectAdded(added), projectId: Fix.other)), .applied)
        XCTAssertEqual(projection.projectOrder, [Fix.project, Fix.other])
        let renamed = Fix.project(Fix.other, name: "сайт")
        XCTAssertEqual(projection.apply(Fix.envelope(3, .projectUpdated(renamed), projectId: Fix.other)), .applied)
        XCTAssertEqual(projection.projects[Fix.other]?.name, "сайт")
        XCTAssertEqual(projection.projectOrder, [Fix.project, Fix.other])
        let pipeline = Fix.pipeline([Fix.stage("backlog", .queue, order: 2), Fix.stage("dev", .agent, order: 0)])
        XCTAssertEqual(projection.apply(Fix.envelope(4, .pipelineApplied(pipeline))), .applied)
        XCTAssertEqual(Set(projection.stageLoad), [retained, unrelated])
        XCTAssertEqual(projection.lanes().first?.columns.map(\.stage.id.rawValue), ["dev", "backlog"])
        XCTAssertEqual(projection.apply(Fix.envelope(5, .projectRemoved(Fix.project))), .applied)
        XCTAssertNil(projection.projects[Fix.project])
        XCTAssertNil(projection.tasks["t-1"])
        XCTAssertEqual(projection.projectOrder, [Fix.other])
    }

    func testHiddenProjectKeepsBadgeCounts() {
        let waiting = Fix.card("t-1", state: .waitingHuman(.question))
        let review = Fix.card("t-2", stage: "test", state: .waitingHuman(.review))
        let project = Fix.project(openIncidentCount: 4)
        let projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [waiting, review], projects: [project], openIncidents: 4))
        XCTAssertEqual(projection.badgeCounts(for: Fix.project).waitingHuman, 2)
        XCTAssertEqual(projection.badgeCounts(for: Fix.project).openIncidents, 4)
        XCTAssertEqual(projection.openIncidentCount, 4)
        let visible = projection.lanes(orderedBy: [])
        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(projection.badgeCounts(for: Fix.project).waitingHuman, 2)
    }

    func testSecondSubscriptionDoesNotApplyTheSameSeqTwice() throws {
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 10, tasks: [Fix.card("t-1")]))
        let other = SubscriptionID(projectIds: [Fix.project])
        projection.openSubscription(other, from: 10)
        let found = SuspiciousFilesFound(taskId: "t-1", runId: nil, stageId: "dev", files: [Fix.file(".env.local")])
        let envelope = Fix.envelope(11, .suspiciousFilesFound(found))
        XCTAssertEqual(projection.apply(envelope, subscription: .all), .applied)
        XCTAssertEqual(projection.apply(envelope, subscription: other), .applied)
        XCTAssertEqual(projection.feed.count, 1)
        XCTAssertEqual(try XCTUnwrap(projection.cursor(for: other)).lastAppliedSeq, 11)

        XCTAssertEqual(projection.apply(Fix.envelope(13, .unknown(type: "gap")), subscription: .all), .gap(expected: 12, received: 13))
        XCTAssertTrue(projection.cursor(for: .all)?.needsResync == true)
        XCTAssertFalse(projection.cursor(for: other)?.needsResync == true)
        XCTAssertEqual(projection.apply(Fix.envelope(12, .taskUpdated(Fix.card("t-1", state: .paused, title: "С другой подписки"))), subscription: other), .applied)
        XCTAssertEqual(projection.tasks["t-1"]?.state, .paused)
        XCTAssertEqual(projection.apply(Fix.envelope(12, .taskUpdated(Fix.card("t-1", title: "Не должно примениться"))), subscription: .all), .needsResync)
        XCTAssertEqual(projection.tasks["t-1"]?.title, "С другой подписки" as String?)
    }

    func testProjectIncidentCountSurvivesSnapshotAndFollowsTheJournal() {
        let project = Fix.project(openIncidentCount: 2, identity: GitIdentity(name: "Artem", email: "a@b.c"))
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, projects: [project], openIncidents: 2))
        XCTAssertEqual(projection.badgeCounts(for: Fix.project).openIncidents, 2)
        XCTAssertEqual(projection.projects[Fix.project]?.identity, GitIdentity(name: "Artem", email: "a@b.c"))

        let incident = Incident(
            id: "i-9", projectId: Fix.project, taskId: "t-1", runId: nil, kind: .configChanged, rolledBack: [], openedAt: Fix.t0
        )
        XCTAssertEqual(projection.apply(Fix.envelope(2, .incidentOpened(incident))), .applied)
        XCTAssertEqual(projection.badgeCounts(for: Fix.project).openIncidents, 2)
        XCTAssertEqual(projection.openIncidentCount, 2)

        var refreshed = project
        refreshed.openIncidentCount = 3
        refreshed.name = "кабан"
        XCTAssertEqual(projection.apply(Fix.envelope(3, .projectUpdated(refreshed))), .applied)
        XCTAssertEqual(projection.badgeCounts(for: Fix.project).openIncidents, 3)
        XCTAssertEqual(projection.projects[Fix.project]?.name, "кабан")
        XCTAssertEqual(projection.projects[Fix.project]?.identity?.email, "a@b.c")

        let resolved = IncidentResolved(incidentId: "i-9", by: .human, commandId: Fix.command)
        XCTAssertEqual(projection.apply(Fix.envelope(4, .incidentResolved(resolved))), .applied)
        XCTAssertEqual(projection.badgeCounts(for: Fix.project).openIncidents, 3)
        XCTAssertEqual(projection.openIncidentCount, 3)

        let unseen = IncidentResolved(incidentId: "i-old", by: .human, commandId: nil)
        XCTAssertEqual(projection.apply(Fix.envelope(5, .incidentResolved(unseen))), .applied)
        XCTAssertEqual(projection.badgeCounts(for: Fix.project).openIncidents, 3)
        XCTAssertEqual(projection.openIncidentCount, 3)

        XCTAssertEqual(projection.apply(Fix.envelope(6, .projectRemoved(Fix.project))), .applied)
        XCTAssertEqual(projection.openIncidentCount, 0)
        XCTAssertNil(projection.projects[Fix.project])
    }

    func testStageLoadAndReadonlyViolationStayOnTheBoard() {
        let load = StageLoad(projectId: Fix.project, stageId: "dev", wipUsed: 1, wipLimit: 2)
        var file = Fix.file(".env.local")
        file.isText = true
        let card = Fix.card("t-1", state: .retryWait(.readonlyViolation), files: [file])
        var projection = BoardProjection(snapshot: Fix.snapshot(seq: 1, tasks: [card], stageLoad: [load]))
        XCTAssertEqual(projection.load(projectId: Fix.project, stageId: "dev"), load)
        XCTAssertEqual(projection.tasks["t-1"]?.state, .retryWait(.readonlyViolation))
        XCTAssertEqual(projection.tasks["t-1"]?.suspiciousFiles.first?.isText, true)

        let next = StageLoad(projectId: Fix.project, stageId: "dev", wipUsed: 2, wipLimit: 2)
        XCTAssertEqual(projection.apply(Fix.envelope(2, .stageLoadChanged(next))), .applied)
        XCTAssertEqual(projection.load(projectId: Fix.project, stageId: "dev"), next)
        XCTAssertEqual(projection.tasks["t-1"], card, "загрузка стадии карточку не меняет")
        XCTAssertEqual(projection.feed.count, 1)

        let other = StageLoad(projectId: Fix.project, stageId: "test", wipUsed: 0, wipLimit: nil)
        XCTAssertEqual(projection.apply(Fix.envelope(3, .stageLoadChanged(other))), .applied)
        XCTAssertEqual(projection.stageLoad.count, 2)
        XCTAssertNil(projection.load(projectId: Fix.project, stageId: "test")?.wipLimit)
    }
}
