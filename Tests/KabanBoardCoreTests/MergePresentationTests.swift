import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class MergePresentationTests: XCTestCase {
    @MainActor func testMockApprovalReportsDurableOrderAndExactReplayDoesNotReadmit() async throws {
        let p = PipelineSummary(projectId: Fix.project, versionHash: "v", stages: [Fix.stage("human", .human, order: 0, onSuccess: "merge"), Fix.stage("merge", .merge, order: 1, onSuccess: "done"), Fix.stage("done", .terminal, order: 2)])
        let client = MockKabanClient(snapshot: .init(seq: 6, projects: [Fix.project()], pipelines: [p], tasks: [Fix.card("review", stage: "human", state: .waitingHuman(.review))]))
        let envelope = CommandEnvelope(command: .approve(taskId: "review"))
        let reply = try await client.send(envelope)
        let first = try await client.getSnapshot()
        XCTAssertEqual(first.tasks[0].state.status, .queued)
        XCTAssertEqual(first.tasks[0].stageId, "merge"); XCTAssertEqual(first.tasks[0].mergeQueueSequence, 7)
        let replay = try await client.send(envelope); XCTAssertEqual(replay, reply)
        let second = try await client.getSnapshot(); XCTAssertEqual(second, first)
        _ = try await client.send(.init(command: .cancelTask(taskId: "review", keepBranch: false)))
        let cancelled = try await client.getSnapshot(); XCTAssertNil(cancelled.tasks[0].mergeQueueSequence)
    }
    func testQueueUsesAdmissionFactsAndNeverInfersOrderFromPriorityOrTime() {
        let p = PipelineSummary(projectId: Fix.project, versionHash: "v", stages: [Fix.stage("merge", .merge, order: 0)])
        var first = Fix.card("z", stage: "merge", state: .blocked(.mainDirty))
        var second = Fix.card("a", stage: "merge", state: .queued(nil))
        first.mergeQueueSequence = 14; second.mergeQueueSequence = 23; second.priority = 99
        let queue = MergePresentation.queue(project: Fix.project, tasks: [second, first, Fix.card("done", stage: "merge", state: .done)], pipeline: p)
        XCTAssertEqual(queue.map(\.id), ["z", "a"])
        XCTAssertEqual(MergePresentation.position("a", queue: queue), 2)
        second.mergeQueueSequence = nil
        XCTAssertNil(MergePresentation.position("z", queue: [first, second]))
        second.mergeQueueSequence = first.mergeQueueSequence
        XCTAssertNil(MergePresentation.position("z", queue: [first, second]))
        XCTAssertTrue(MergePresentation.queue(project: Fix.project, tasks: queue, pipeline: nil).isEmpty)
    }
    func testDoneRequiresConfirmedResultAndUnknownPayloadIsPreserved() throws {
        let result = LocalMergeResult(baseCommit: String(repeating: "a", count: 40), commit: String(repeating: "b", count: 40), ref: "refs/heads/main")
        var detail = TaskDetail(seq: 4, task: Fix.card("done", stage: "done", state: .done), feed: [], runs: [])
        XCTAssertNil(MergePresentation.result(detail))
        detail.artifacts = [.init(id: "result", taskId: "done", kind: "merge_result", text: String(decoding: try KabanCoding.makeEncoder().encode(result), as: UTF8.self), createdAt: Fix.t0)]
        XCTAssertEqual(MergePresentation.result(detail), result)
        detail.task.state = .gating; XCTAssertNil(MergePresentation.result(detail))
        detail.task.state = .done; detail.artifacts[0].text = "Future complete format"
        XCTAssertNil(MergePresentation.result(detail)); XCTAssertEqual(detail.artifacts[0].text, "Future complete format")
    }
    func testMergeLimitAllowsExplicitReturnButNeverApprove() throws {
        let p = PipelineSummary(projectId: Fix.project, versionHash: "v", stages: [Fix.stage("dev", .agent, order: 0, onSuccess: "human"), Fix.stage("human", .human, order: 1, onSuccess: "merge"), Fix.stage("merge", .merge, order: 2, onSuccess: "done"), Fix.stage("done", .terminal, order: 3)], defaultReturnStage: "dev")
        let detail = TaskDetail(seq: 3, task: Fix.card("limit", stage: "merge", state: .waitingHuman(.conflictLimit)), feed: [], runs: [])
        var reported = p
        XCTAssertNil(HumanReviewContext(detail: detail, pipeline: p)?.defaultTarget, "A missing onConflict cannot borrow the global default")
        reported.defaultReturnStage = nil
        reported.stages[2].onConflict = .init(stage: "dev", limit: 2)
        let context = try XCTUnwrap(HumanReviewContext(detail: detail, pipeline: reported))
        XCTAssertEqual(context.defaultTarget, "dev", "Use the resolved onConflict source fact")
        XCTAssertEqual(context.targets.map(\.id), ["dev"])
        XCTAssertEqual(context.command(.requestChanges, current: context, comments: "Fix conflict", target: "dev", cancel: false, keepBranch: false), .requestChanges(taskId: "limit", comments: "Fix conflict", target: "dev"))
        XCTAssertNil(context.command(.approve, current: context, comments: "", target: nil, cancel: false, keepBranch: false))
    }
}
