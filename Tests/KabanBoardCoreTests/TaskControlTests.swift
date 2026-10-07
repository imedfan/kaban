import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class TaskControlTests: XCTestCase {
    func testPauseAndRetryAffordancesFollowReceiverStates() {
        for state in [TaskState.queued(nil), .queued(.quotaCm), .running, .gating, .retryWait(.rateLimit), .waitingHuman(.review)] {
            XCTAssertTrue(TaskActions.canPause(Fix.card("a", state: state)))
        }
        for state in [TaskState.paused, .waitingHuman(.question), .waitingHuman(.incident), .done, .cancelled] {
            XCTAssertFalse(TaskActions.canPause(Fix.card("a", state: state)))
        }
        XCTAssertTrue(TaskActions.canResume(Fix.card("a", state: .paused)))
        XCTAssertFalse(TaskActions.canRetry(Fix.card("a", state: .waitingHuman(.review))))
        XCTAssertTrue(TaskActions.canRetry(Fix.card("a", state: .waitingHuman(.retriesExhausted))))
    }
    func testTypedDragRejectsChangedCardPipelineGenerationAndProjectWithoutMutating() throws {
        let card = Fix.card("a", stage: "test", state: .running)
        let generation = UUID(), pipeline = Fix.pipeline(), target = pipeline.stages[0]
        let payload = TaskDragItem(card: card, pipelineVersion: pipeline.versionHash, generation: generation)
        let decoded = try JSONDecoder().decode(TaskDragItem.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(payload.decision(current: card, target: target, pipeline: pipeline, generation: generation),
                       .allowed(interruptConfirmation: DropRules.interruptConfirmation))
        for current in [Fix.card("a", stage: "test", state: .paused), Fix.card("a", stage: "test", state: .running, title: "Changed")] {
            XCTAssertEqual(payload.decision(current: current, target: target, pipeline: pipeline, generation: generation), .forbidden(.staleTask))
        }
        XCTAssertEqual(payload.decision(current: card, target: target, pipeline: pipeline, generation: UUID()), .forbidden(.staleTask))
        var changed = pipeline; changed.versionHash = "other"
        XCTAssertEqual(payload.decision(current: card, target: target, pipeline: changed, generation: generation), .forbidden(.staleTask))
        XCTAssertEqual(payload.decision(current: card, target: target, pipeline: Fix.pipeline(project: Fix.other), generation: generation), .forbidden(.crossProject))
        let legacy = TaskDragItem(card: card, pipelineVersion: nil, generation: generation)
        XCTAssertEqual(legacy.decision(current: card, target: target, pipeline: pipeline, generation: generation), .forbidden(.unknownPipelineVersion))
        XCTAssertEqual(card.state, .running)
    }
    func testConfirmationRechecksCurrentCardAndPreservesExplicitCancelAndGrantValues() {
        let card = Fix.card("a", stage: "test", state: .running)
        let move = TaskControlRequest(card: card, action: .move("backlog"))
        XCTAssertEqual(move.command(current: card, pipeline: Fix.pipeline()), .moveTask(taskId: "a", stage: "backlog"))
        XCTAssertNil(move.command(current: Fix.card("a", state: .paused), pipeline: Fix.pipeline()))
        let cancel = TaskControlRequest(card: card, action: .cancel)
        XCTAssertEqual(cancel.command(current: card, pipeline: nil), .cancelTask(taskId: "a", keepBranch: false))
        XCTAssertEqual(cancel.command(current: card, pipeline: nil, keepBranch: true), .cancelTask(taskId: "a", keepBranch: true))
        let waiting = Fix.card("w", state: .waitingHuman(.retriesExhausted))
        let retry = TaskControlRequest(card: waiting, action: .retry)
        XCTAssertEqual(retry.command(current: waiting, pipeline: nil), .retryStage(taskId: "w", grantAttempts: nil))
        XCTAssertEqual(retry.command(current: waiting, pipeline: nil, grantAttempts: 4), .retryStage(taskId: "w", grantAttempts: 4))
        XCTAssertNil(retry.command(current: waiting, pipeline: nil, grantAttempts: -1))
    }
    func testUnknownBacklogRouteAndTerminalCannotBeClaimedAsValid() {
        let card = Fix.card("q", stage: "backlog", hasAcceptanceCriteria: true)
        var pipeline = Fix.pipeline(); pipeline.stages[0].onSuccess = nil
        XCTAssertEqual(DropRules.evaluate(card: card, target: pipeline.stages[1], in: pipeline), .forbidden(.unknownRoute))
        pipeline.stages[0].onSuccess = "test"
        XCTAssertEqual(DropRules.evaluate(card: card, target: pipeline.stages[1], in: pipeline), .forbidden(.forwardMove))
        XCTAssertEqual(DropRules.evaluate(card: card, target: pipeline.stages.last!, in: pipeline), .forbidden(.terminalColumn))
    }
    func testProjectPauseConfirmationRequiresTheCorrelatedCompleteFlagSet() {
        let pause = Command.pauseProject(projectId: Fix.project)
        let resume = Command.resumeProject(projectId: Fix.project)
        let present = JournalEvent.settingsChanged(.init(key: "scheduler", value: "updated", schedulerFlags: [.projectPaused(Fix.project)]))
        let removed = JournalEvent.settingsChanged(.init(key: "scheduler", value: "updated", schedulerFlags: [.macPaused]))
        let unknown = JournalEvent.settingsChanged(.init(key: "scheduler", value: "updated"))
        XCTAssertTrue(pause.isConfirmed(by: present)); XCTAssertFalse(pause.isConfirmed(by: removed))
        XCTAssertTrue(resume.isConfirmed(by: removed)); XCTAssertFalse(resume.isConfirmed(by: present))
        XCTAssertFalse(pause.isConfirmed(by: unknown)); XCTAssertFalse(resume.isConfirmed(by: unknown))
        XCTAssertFalse(pause.isConfirmed(by: .taskUpdated(Fix.card("task"))))
    }
    @MainActor func testMockPauseReviewRetryAndGlobalFlagsAreTypedIdempotentAndDoNotStopOtherCards() async throws {
        var waiting = Fix.card("wait", state: .waitingHuman(.retriesExhausted))
        waiting.attempt = 3; waiting.maxAttempts = 3
        let client = MockKabanClient(snapshot: Fix.snapshot(tasks: [
            Fix.card("review", stage: "human", state: .waitingHuman(.review)),
            Fix.card("run", state: .running), waiting
        ]))
        let pause = CommandEnvelope(command: .pauseTask(taskId: "review"))
        let first = try await client.send(pause)
        XCTAssertEqual(first.result, .ok)
        let duplicate = try await client.send(pause); XCTAssertEqual(duplicate, first)
        let paused = try await client.getSnapshot()
        XCTAssertEqual(paused.tasks.first { $0.id == "review" }?.state, .paused)
        XCTAssertEqual(paused.tasks.first { $0.id == "run" }?.state, .running)
        _ = try await client.send(.init(command: .resumeTask(taskId: "review")))
        _ = try await client.send(.init(command: .pauseAll))
        _ = try await client.send(.init(command: .pauseProject(projectId: Fix.project)))
        let flags = try await client.getSnapshot()
        XCTAssertEqual(flags.tasks.first { $0.id == "review" }?.state, .waitingHuman(.review))
        XCTAssertEqual(flags.tasks.first { $0.id == "run" }?.state, .running)
        XCTAssertTrue(flags.schedulerFlags.contains(.macPaused))
        XCTAssertTrue(flags.schedulerFlags.contains(.projectPaused(Fix.project)))
        let retry = CommandEnvelope(command: .retryStage(taskId: "wait", grantAttempts: 4))
        _ = try await client.send(retry); _ = try await client.send(retry)
        let after = try await client.getSnapshot()
        XCTAssertEqual(after.tasks.first { $0.id == "wait" }?.maxAttempts, 7)
        XCTAssertEqual(after.tasks.first { $0.id == "wait" }?.state, .queued(nil))
        _ = try await client.send(.init(command: .moveTask(taskId: "wait", stage: "backlog")))
        let moved = try await client.getSnapshot().tasks.first { $0.id == "wait" }
        XCTAssertEqual(moved?.attempt, 0); XCTAssertNil(moved?.maxAttempts); XCTAssertNil(moved?.model)
    }

}
