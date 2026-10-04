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
        XCTAssertEqual(CardPresentation(state: .queued(.quotaOm)).label, "Ждёт квоту")
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
        XCTAssertEqual(projection.tasks["23"]?.state, .running)
        let nextResumeLoad = await iterator.next()
        _ = projection.apply(try XCTUnwrap(nextResumeLoad))
        XCTAssertEqual(projection.load(projectId: "kaban", stageId: "dev")?.wipUsed, 1)
    }

    @MainActor func testUnsupportedAndInvalidCommandsDoNotMutateSnapshot() async throws {
        let client = MockKabanClient()
        let before = try await client.getSnapshot()
        let result = try await client.send(.approve(taskId: "25"), commandId: UUID())
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
}
