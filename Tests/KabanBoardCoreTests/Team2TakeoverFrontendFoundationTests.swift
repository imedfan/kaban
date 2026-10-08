import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class Team2TakeoverFrontendFoundationTests: XCTestCase {
    func testRedReservedForIncidentAndReviewIsTeal() {
        for reason in WaitingHumanReason.allCases {
            let presentation = CardPresentation(state: .waitingHuman(reason))
            XCTAssertEqual(presentation.tone == .incident, reason == .incident)
            XCTAssertEqual(presentation.tone == .review, reason == .review)
        }
        XCTAssertEqual(CardPresentation(state: .waitingHuman(.suspiciousFiles)).tone, .waiting)
        XCTAssertEqual(CardPresentation(state: .queued(.wipFull)).label, "Ждёт места")
        XCTAssertEqual(CardPresentation(state: .queued(.quotaOm)).label, "Ждёт квоту Om")
    }

    @MainActor func testMockCommandsPublishCorrelatedAuthoritativeCards() async throws {
        let client = MockKabanClient()
        var projection = BoardProjection(snapshot: try await client.getSnapshot())
        let stream = client.events()
        var iterator = stream.makeAsyncIterator()
        let commandID = UUID()
        projection.markSent(commandId: commandID, taskId: "23", at: Date())
        let result = try await client.send(.pauseTask(taskId: "23"), commandId: commandID)
        XCTAssertEqual(result, .ok)
        // Acknowledgement alone has not changed the projection or cleared the pending command.
        XCTAssertEqual(projection.tasks["23"]?.state, .running)
        XCTAssertTrue(projection.isSent("23"))
        let next = await iterator.next()
        let event = try XCTUnwrap(next)
        XCTAssertEqual(event.commandId, commandID)
        XCTAssertEqual(projection.apply(event), .applied)
        XCTAssertEqual(projection.tasks["23"]?.state, .paused)
        XCTAssertFalse(projection.isSent("23"))
        let nextLoad = await iterator.next()
        let loadEvent = try XCTUnwrap(nextLoad)
        XCTAssertEqual(projection.apply(loadEvent), .applied)
        XCTAssertEqual(projection.load(projectId: "kaban", stageId: "dev")?.wipUsed, 0)
        let snapshot = try await client.getSnapshot()
        XCTAssertEqual(snapshot.seq, loadEvent.seq)
        XCTAssertEqual(snapshot.tasks.first { $0.id == "23" }?.state, .paused)
        let detailResult = try await client.send(.getTaskDetail(taskId: "23"), commandId: UUID())
        guard case .taskDetail(let detail) = detailResult else { return XCTFail("Expected typed task detail") }
        XCTAssertEqual(detail.seq, snapshot.seq)
        XCTAssertEqual(detail.task.state, .paused)
        XCTAssertEqual(detail.feed.count, 1)
        let resumeResult = try await client.send(.resumeTask(taskId: "23"), commandId: UUID())
        XCTAssertEqual(resumeResult, .ok)
        let nextResumed = await iterator.next()
        let resumed = try XCTUnwrap(nextResumed)
        _ = projection.apply(resumed)
        XCTAssertEqual(projection.tasks["23"]?.state, .queued(nil))
        XCTAssertEqual(projection.load(projectId: "kaban", stageId: "dev")?.wipUsed, 0)
    }

    @MainActor func testUnsupportedAndInvalidCommandsDoNotMutateSnapshot() async throws {
        var fixture = MockKabanClient.fixture()
        fixture.tasks[fixture.tasks.firstIndex { $0.id == "25" }!].state = .waitingHuman(.question)
        let client = MockKabanClient(snapshot: fixture)
        let before = try await client.getSnapshot()
        let result = try await client.send(.recheck(scope: .runner), commandId: UUID())
        guard case .error(let error) = result else { return XCTFail("Expected explicit unsupported error") }
        XCTAssertEqual(error.code, "unknown_command")
        let invalid = try await client.send(.pauseTask(taskId: "25"), commandId: UUID())
        guard case .error(let invalidError) = invalid else { return XCTFail("Expected invalid state") }
        XCTAssertEqual(invalidError.code, "invalid_state")
        let after = try await client.getSnapshot()
        XCTAssertEqual(after, before)
    }

    @MainActor func testFixtureProjectsAndDaemonWIPRemainIndependentOfVisibleLanes() async throws {
        let snapshot = try await MockKabanClient().getSnapshot()
        let board = BoardProjection(snapshot: snapshot)
        XCTAssertEqual(board.lanes().count, 2)
        XCTAssertEqual(board.lanes(orderedBy: ["shop"]).count, 1)
        XCTAssertEqual(board.tasks.count, 5)
        XCTAssertEqual(board.load(projectId: "kaban", stageId: "dev")?.wipUsed, 1)
        XCTAssertNil(board.load(projectId: "shop", stageId: "dev"))
    }

    @MainActor func testCreationRoundTripsMarkdownAndReplaysWithoutExtraCardOrEvent() async throws {
        let client = MockKabanClient()
        var board = BoardProjection(snapshot: try await client.getSnapshot())
        var pending = TaskCreationPending()
        let stream = client.events()
        var events = stream.makeAsyncIterator()
        let commandID = UUID()
        let draft = DemoTaskDraft(title: "  Unicode 🐗  ", description: "# Задача\n\n**Markdown**\n", acceptanceCriteria: "- [ ] Проверить\n")
        XCTAssertTrue(pending.begin(commandID: commandID, projectID: "shop"))
        XCTAssertFalse(pending.begin(commandID: UUID(), projectID: "kaban"))
        let command = Command.createTask(projectId: "shop", title: draft.title, body: draft.body)
        let receipt = try await client.send(command, commandId: commandID)
        // The event may reach the consumer before the command receipt is handled.
        let next1 = await events.next()
        let event = try XCTUnwrap(next1)
        XCTAssertEqual(board.apply(event), .applied)
        let id = try XCTUnwrap(pending.finish(with: event))
        XCTAssertEqual(receipt, .taskCreated(id))
        XCTAssertNil(pending.commandID)
        pending.fail(commandID) // A late transport failure cannot undo an applied event.
        XCTAssertEqual(board.tasks[id]?.projectId, "shop")
        XCTAssertEqual(board.tasks[id]?.title, "Unicode 🐗")
        XCTAssertEqual(board.tasks[id]?.stageId, "backlog")
        XCTAssertEqual(board.tasks[id]?.hasAcceptanceCriteria, true)
        guard case .taskDetail(let detail) = try await client.send(.getTaskDetail(taskId: id), commandId: UUID()) else { return XCTFail("detail") }
        XCTAssertEqual(detail.body, draft.body)
        let beforeReplay = try await client.getSnapshot()
        let actual2 = try await client.send(command, commandId: commandID)
        XCTAssertEqual(actual2, receipt)
        let actual3 = try await client.getSnapshot()
        XCTAssertEqual(actual3, beforeReplay)
        guard case .error(let mismatch) = try await client.send(.createTask(projectId: "kaban", title: "Other", body: ""), commandId: commandID) else { return XCTFail("conflict") }
        XCTAssertEqual(mismatch.code, "command_id_conflict")
        let actual4 = try await client.getSnapshot()
        XCTAssertEqual(actual4, beforeReplay)
    }

    @MainActor func testUnknownBodyTitleEditAndExactKnownBodyIncludingEmpty() async throws {
        let markdown = "# Custom heading\n\n## Критерии приёмки\n- first\n\n## Критерии приёмки\n- second\n"
        let client = MockKabanClient(taskBodies: ["24": markdown])
        for (id, expected) in [(TaskID(rawValue: "24"), Optional(markdown)), (TaskID(rawValue: "25"), nil)] {
            guard case .taskDetail(let before) = try await client.send(.getTaskDetail(taskId: id), commandId: UUID()) else { return XCTFail("detail") }
            XCTAssertEqual(before.body, expected)
            let actual5 = try await client.send(.editTask(taskId: id, title: "Changed", body: nil), commandId: UUID())
            XCTAssertEqual(actual5, .ok)
            guard case .taskDetail(let after) = try await client.send(.getTaskDetail(taskId: id), commandId: UUID()) else { return XCTFail("detail") }
            XCTAssertEqual(after.body, expected)
            XCTAssertEqual(after.task.title, "Changed")
        }
        let actual6 = try await client.send(.editTask(taskId: "24", title: nil, body: ""), commandId: UUID())
        XCTAssertEqual(actual6, .ok)
        guard case .taskDetail(let empty) = try await client.send(.getTaskDetail(taskId: "24"), commandId: UUID()) else { return XCTFail("detail") }
        XCTAssertEqual(empty.body, "")
        XCTAssertFalse(empty.task.hasAcceptanceCriteria)
    }

    @MainActor func testAuthoritativeMoveCancelValidationAndPreservedBranch() async throws {
        let client = MockKabanClient()
        let before = try await client.getSnapshot()
        for command in [Command.moveTask(taskId: "24", stage: "test"), .moveTask(taskId: "23", stage: "review"), .editTask(taskId: "23", title: "No", body: nil), .createTask(projectId: "missing", title: "No", body: "")] {
            guard case .error = try await client.send(command, commandId: UUID()) else { return XCTFail("Expected validation") }
            let actual7 = try await client.getSnapshot()
            XCTAssertEqual(actual7, before)
        }
        let stream = client.events()
        var iterator = stream.makeAsyncIterator()
        let moveID = UUID()
        let actual8 = try await client.send(.moveTask(taskId: "23", stage: "backlog"), commandId: moveID)
        XCTAssertEqual(actual8, .ok)
        let next9 = await iterator.next()
        let moved = try XCTUnwrap(next9)
        XCTAssertEqual(moved.commandId, moveID)
        guard case .taskUpdated(let movedCard) = moved.event else { return XCTFail("card") }
        XCTAssertEqual(movedCard.stageId, "backlog")
        XCTAssertEqual(movedCard.state, .queued(nil))
        XCTAssertEqual(movedCard.attempt, 0, "A manual move starts a new stage visit, as TaskMachine.enter does")
        let cancelID = UUID()
        let actual10 = try await client.send(.cancelTask(taskId: "23", keepBranch: true), commandId: cancelID)
        XCTAssertEqual(actual10, .ok)
        let cancelledSnapshot = try await client.getSnapshot()
        XCTAssertEqual(cancelledSnapshot.tasks.first { $0.id == "23" }?.branch, "kaban/task-23")
        XCTAssertEqual(cancelledSnapshot.tasks.first { $0.id == "23" }?.state, .cancelled)
        guard case .error = try await client.send(.moveTask(taskId: "23", stage: "dev"), commandId: UUID()) else { return XCTFail("terminal task") }
        let actual11 = try await client.getSnapshot()
        XCTAssertEqual(actual11, cancelledSnapshot)
    }

    @MainActor func testCreationCorrelationAndSameTaskDetailRefreshGeneration() {
        var pending = TaskCreationPending()
        let id = UUID()
        XCTAssertTrue(pending.begin(commandID: id, projectID: "kaban"))
        let card = MockKabanClient.fixture().tasks[0]
        let unrelated = EventEnvelope(seq: 1, at: Date(), projectId: "kaban", commandId: UUID(), event: .taskCreated(card))
        XCTAssertNil(pending.finish(with: unrelated))
        var wrongProject = card; wrongProject.projectId = "shop"
        XCTAssertNil(pending.finish(with: EventEnvelope(seq: 2, at: Date(), projectId: "shop", commandId: id, event: .taskCreated(wrongProject))))
        XCTAssertEqual(pending.commandID, id)
        pending.fail(UUID()); XCTAssertEqual(pending.commandID, id)
        pending.fail(id); XCTAssertNil(pending.commandID)
        var selection = TaskDetailSelection()
        let first = selection.begin("24")
        let newer = selection.begin("24")
        XCTAssertFalse(selection.accepts(first, taskID: "24"))
        XCTAssertTrue(selection.accepts(newer, taskID: "24"))
        let card24 = MockKabanClient.fixture().tasks.first { $0.id == "24" }!
        let detail = TaskDetail(seq: 10, task: card24, feed: [], runs: [])
        XCTAssertTrue(selection.accepts(newer, detail: detail, minimumSeq: 10))
        XCTAssertFalse(selection.accepts(newer, detail: detail, minimumSeq: 11))
        var wrongDetail = detail; wrongDetail.task.id = "25"
        XCTAssertFalse(selection.accepts(newer, detail: wrongDetail, minimumSeq: 0))
        _ = selection.begin(nil)
        XCTAssertFalse(selection.accepts(newer, taskID: "24"))
    }


    @MainActor func testBacklogCreationAllowedWhenProjectMissingOrPipelineInvalidButMoveRejected() async throws {
        var snapshot = MockKabanClient.fixture()
        snapshot.projects[0].availability = .missing
        snapshot.pipelines[1].issues = [.init(path: "pipeline", code: "pipeline_invalid", message: "Invalid fixture pipeline", severity: .error)]
        let client = MockKabanClient(snapshot: snapshot)
        for projectID: ProjectID in ["kaban", "shop"] {
            let result = try await client.send(.createTask(projectId: projectID, title: "Stored safely", body: "Description\n\n## Критерии приёмки\n- yes"), commandId: UUID())
            guard case .taskCreated(let id) = result else { return XCTFail("Unavailable project still accepts Backlog storage") }
            let created = try await client.getSnapshot()
            XCTAssertEqual(created.tasks.first { $0.id == id }?.stageId, "backlog")
            guard case .error = try await client.send(.moveTask(taskId: id, stage: "dev"), commandId: UUID()) else { return XCTFail("Unavailable pipeline must not start work") }
            let after = try await client.getSnapshot()
            XCTAssertEqual(after, created)
        }
    }


    @MainActor func testEditPendingClearsOnlyAfterCorrelatedCardAndErrorsStayAuthoritative() async throws {
        let client = MockKabanClient()
        var board = BoardProjection(snapshot: try await client.getSnapshot())
        var events = client.events().makeAsyncIterator()
        let id = UUID()
        board.markSent(commandId: id, taskId: "24", at: Date())
        let receipt = try await client.send(.editTask(taskId: "24", title: "Edited", body: nil), commandId: id)
        XCTAssertEqual(receipt, .ok)
        XCTAssertTrue(board.isSent("24"))
        let nextEdited = await events.next()
        let edited = try XCTUnwrap(nextEdited)
        XCTAssertEqual(board.apply(edited), .applied)
        XCTAssertEqual(board.tasks["24"]?.title, "Edited")
        XCTAssertTrue(board.isSent("24"))
        let nextUpdated = await events.next()
        let updated = try XCTUnwrap(nextUpdated)
        XCTAssertEqual(board.apply(updated), .applied)
        XCTAssertFalse(board.isSent("24"))
        let before = try await client.getSnapshot()
        let errorID = UUID()
        board.markSent(commandId: errorID, taskId: "23", at: Date())
        guard case .error = try await client.send(.editTask(taskId: "23", title: "Forbidden", body: nil), commandId: errorID) else { return XCTFail("invalid edit") }
        board.noteCommandError(errorID)
        XCTAssertFalse(board.isSent("23"))
        XCTAssertEqual(board.tasks["23"]?.state, .running)
        let after = try await client.getSnapshot()
        XCTAssertEqual(after, before)
    }

}
