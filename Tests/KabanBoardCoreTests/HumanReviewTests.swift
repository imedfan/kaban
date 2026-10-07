import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class HumanReviewTests: XCTestCase {
    private func pipeline() -> PipelineSummary {
        var read = Fix.stage("read", .agent, order: -2, onSuccess: "human"); read.readOnly = true
        return .init(projectId: Fix.project, versionHash: "v1", stages: [
            Fix.stage("dev", .agent, order: 8, onSuccess: "test"),
            Fix.stage("test", .agent, order: 7, onSuccess: "read"), read,
            Fix.stage("human", .human, order: 1, onSuccess: "merge"),
            Fix.stage("merge", .merge, order: 2, onSuccess: "done"), Fix.stage("done", .terminal, order: 3),
            Fix.stage("disconnected", .agent, order: 0, onSuccess: "done")
        ], defaultReturnStage: "dev")
    }
    private func detail() -> TaskDetail {
        .init(seq: 10, task: Fix.card("r", stage: "human", state: .waitingHuman(.review)), feed: [], runs: [],
              artifacts: [.init(id: "summary", taskId: "r", stageId: "dev", kind: "summary", text: "Real result", createdAt: Fix.t0)])
    }
    func testReturnChoicesUseOnSuccessAndExcludeReadOnlyDisconnectedForwardAndCycles() {
        var p = pipeline(), card = detail().task
        XCTAssertEqual(HumanReviewContext.returnTargets(card: card, pipeline: p).map(\.id), ["dev", "test"])
        p.stages[1].onSuccess = "dev"
        XCTAssertTrue(HumanReviewContext.returnTargets(card: card, pipeline: p).isEmpty)
        p = pipeline(); p.stages.append(p.stages[0])
        XCTAssertTrue(HumanReviewContext.returnTargets(card: card, pipeline: p).isEmpty)
        p = pipeline(); card.projectId = Fix.other
        XCTAssertTrue(HumanReviewContext.returnTargets(card: card, pipeline: p).isEmpty)
    }
    func testExactCommentExplicitTargetAndRejectKeepBranchRules() throws {
        let context = try XCTUnwrap(HumanReviewContext(detail: detail(), pipeline: pipeline()))
        let text = "Check status first  \r\n👋"
        func command(_ decision: HumanReviewDecision, target: StageID? = "dev", cancel: Bool = false, keep: Bool = true, comments: String = text) -> Command? {
            context.command(decision, current: context, comments: comments, target: target, cancel: cancel, keepBranch: keep)
        }
        XCTAssertEqual(command(.approve), .approve(taskId: "r"))
        XCTAssertEqual(command(.requestChanges), .requestChanges(taskId: "r", comments: text, target: "dev"))
        XCTAssertNil(command(.requestChanges, target: nil)); XCTAssertNil(command(.requestChanges, target: "read"))
        XCTAssertNil(command(.requestChanges, comments: " \n")); XCTAssertNil(command(.requestChanges, comments: "x\0"))
        XCTAssertEqual(command(.reject, cancel: true), .reject(taskId: "r", target: .cancel, keepBranch: true))
        XCTAssertEqual(command(.reject, target: "test"), .reject(taskId: "r", target: .stage(stageId: "test"), keepBranch: false))
        XCTAssertNil(command(.reject, target: "merge"))
        var p = pipeline(); p.defaultReturnStage = nil
        let legacy = try XCTUnwrap(HumanReviewContext(detail: detail(), pipeline: p))
        XCTAssertNil(legacy.defaultTarget)
        XCTAssertNil(legacy.command(.requestChanges, current: legacy, comments: text, target: "dev", cancel: false, keepBranch: false))
        XCTAssertEqual(legacy.command(.reject, current: legacy, comments: "", target: nil, cancel: true, keepBranch: false), .reject(taskId: "r", target: .cancel, keepBranch: false))
    }
    func testOnlyHumanReviewAndExactMaterialsPipelineOrCardAllowDecision() throws {
        let original = try XCTUnwrap(HumanReviewContext(detail: detail(), pipeline: pipeline()))
        var changed = detail(); changed.artifacts[0].text = "New result"
        let current = try XCTUnwrap(HumanReviewContext(detail: changed, pipeline: pipeline()))
        XCTAssertNil(original.command(.approve, current: current, comments: "", target: nil, cancel: true, keepBranch: false))
        for state in [TaskState.running, .gating, .paused, .queued(nil), .waitingHuman(.question), .done, .cancelled] {
            changed.task.state = state; XCTAssertNil(HumanReviewContext(detail: changed, pipeline: pipeline()))
        }
        for kind in [StageKind.agent, .gate, .merge] {
            var p = pipeline(); p.stages[3].kind = kind
            XCTAssertNil(HumanReviewContext(detail: detail(), pipeline: p))
        }
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CommandError(code: "test_timeout", message: "Review timeout")
    }
    @MainActor func testStaleMaterialCommentSurvivesReopenAndRequiresExplicitReview() async throws {
        let client = ReviewTestClient(detail: detail(), pipeline: pipeline()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "session")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }; await session.select("r")
        let review = HumanReviewStore(session: session, storage: storage, key: "review")
        review.edit("r", comments: "Exact  \r\n👋", target: "test")
        client.detail.artifacts[0].text = "Updated result"; await session.retryDetail()
        let reopened = HumanReviewStore(session: session, storage: storage, key: "review")
        XCTAssertTrue(reopened.isStale("r")); XCTAssertFalse(reopened.canSubmit(.approve, for: "r"))
        let refused = await reopened.submit(.requestChanges, for: "r"); XCTAssertFalse(refused); XCTAssertTrue(client.sent.isEmpty)
        XCTAssertEqual(reopened.draft(for: "r")?.comments, "Exact  \r\n👋")
        reopened.useCurrentReview("r")
        XCTAssertEqual(reopened.draft(for: "r")?.target, "test"); XCTAssertTrue(reopened.canSubmit(.requestChanges, for: "r"))
    }
    @MainActor func testOKAndDoubleDecisionWaitForCorrelatedMergeQueue() async throws {
        let client = ReviewTestClient(detail: detail(), pipeline: pipeline()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "session")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }; await session.select("r")
        let review = HumanReviewStore(session: session, storage: storage, key: "review")
        let sent = await review.submit(.approve, for: "r"); XCTAssertTrue(sent)
        try await wait { session.canSend }
        XCTAssertEqual(review.receipt(for: "r")?.phase, .awaitingEvent)
        XCTAssertEqual(session.projection?.tasks["r"]?.state, .waitingHuman(.review))
        let second = await review.submit(.reject, for: "r"); XCTAssertFalse(second)
        XCTAssertEqual(Set(client.sent.map(\.commandId)).count, 1)
        var card = client.detail.task; card.stageId = "merge"; card.state = .queued(nil)
        try session.consume(.event(Fix.envelope(11, .taskUpdated(card), commandId: client.sent[0].commandId)))
        XCTAssertEqual(review.receipt(for: "r")?.phase, .applied)
        XCTAssertEqual(session.projection?.tasks["r"]?.state, .queued(nil)); XCTAssertNotEqual(card.state, .done)
    }
    @MainActor func testInvalidStateRefreshPreservesCommentAndHasInlineFailure() async throws {
        let client = ReviewTestClient(detail: detail(), pipeline: pipeline()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "session")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }; await session.select("r")
        let review = HumanReviewStore(session: session, storage: storage, key: "review")
        review.edit("r", comments: "Preserve this comment"); client.refuse = true
        let sent = await review.submit(.requestChanges, for: "r"); XCTAssertFalse(sent)
        XCTAssertEqual(session.detail?.artifacts[0].text, "Updated by another client")
        XCTAssertNil(session.error); XCTAssertTrue(review.isStale("r"))
        XCTAssertEqual(review.draft(for: "r")?.comments, "Preserve this comment")
    }
    @MainActor func testOfflineDraftAndCorruptStorageDoNotSendOrOverwrite() async throws {
        let client = ReviewTestClient(detail: detail(), pipeline: pipeline()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "session")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }; await session.select("r")
        let review = HumanReviewStore(session: session, storage: storage, key: "review")
        try session.consume(.connection(.reconnecting(lastSeq: 10)))
        review.edit("r", comments: "Offline comment")
        XCTAssertFalse(review.canSubmit(.requestChanges, for: "r"))
        XCTAssertEqual(HumanReviewStore(session: session, storage: storage, key: "review").draft(for: "r")?.comments, "Offline comment")
        storage.set(Data("bad".utf8), forKey: "bad")
        let corrupt = HumanReviewStore(session: session, storage: storage, key: "bad")
        corrupt.edit("r", comments: "Cannot replace")
        XCTAssertNotNil(corrupt.storageError); XCTAssertEqual(storage.data(forKey: "bad"), Data("bad".utf8))
    }
    @MainActor func testMockApproveReturnRejectAndIdempotenceFollowServerFacts() async throws {
        var p = pipeline(); p.stages[0].maxAttempts = 3; p.stages[0].model = "explicit"
        var card = detail().task; card.branch = "kaban/r"; card.priority = 7; card.runsSinceHuman = 12; card.bounceByReason = ["merge_conflict": 1]
        for command in [Command.approve(taskId: "r"), .requestChanges(taskId: "r", comments: "Fix it", target: "dev"), .reject(taskId: "r", target: .stage(stageId: "test"), keepBranch: true), .reject(taskId: "r", target: .cancel, keepBranch: true)] {
            let client = MockKabanClient(snapshot: Fix.snapshot(tasks: [card], pipelines: [p]))
            let envelope = CommandEnvelope(command: command), first = try await client.send(envelope), second = try await client.send(envelope)
            XCTAssertEqual(first.result, .ok); XCTAssertEqual(first, second)
            let snapshot = try await client.getSnapshot(), updated = try XCTUnwrap(snapshot.tasks.first)
            XCTAssertEqual(updated.priority, 7); XCTAssertEqual(updated.runsSinceHuman, 0); XCTAssertEqual(updated.bounceByReason, card.bounceByReason)
            switch command {
            case .approve: XCTAssertEqual(updated.stageId, "merge"); XCTAssertEqual(updated.state, .queued(nil))
            case .requestChanges: XCTAssertEqual(updated.stageId, "dev"); XCTAssertEqual(updated.attempt, 0); XCTAssertEqual(updated.model, "explicit")
            case .reject(_, .stage, _): XCTAssertEqual(updated.stageId, "test"); XCTAssertEqual(updated.state, .queued(nil))
            case .reject(_, .cancel, _): XCTAssertEqual(updated.state, .cancelled); XCTAssertEqual(updated.branch, "refs/kaban/archive/r")
            default: XCTFail("Unexpected command")
            }
        }
        let client = MockKabanClient(snapshot: Fix.snapshot(tasks: [card], pipelines: [p]))
        let invalid = try await client.send(.init(command: .reject(taskId: "r", target: .stage(stageId: "read"), keepBranch: false)))
        guard case .error = invalid.result else { return XCTFail("Read-only target accepted") }
    }
    func testDiffstatExactNumstatBinaryAndScaledStatNeverInventPerFileCounts() throws {
        let exact = try XCTUnwrap(ReviewMaterialPresentation.files("14\t3\tSources/a.swift\n-\t-\timage.png\n"))
        XCTAssertEqual(exact[0].additions, 14); XCTAssertEqual(exact[0].deletions, 3); XCTAssertEqual(exact[0].changes, 17)
        XCTAssertTrue(exact[1].binary); XCTAssertNil(exact[1].changes)
        let scaled = try XCTUnwrap(ReviewMaterialPresentation.files(" Sources/a.swift | 1000 +++--\n path with spaces | 0\n image.png | Bin 12 -> 15 bytes\n 3 files changed, 100 insertions(+), 9 deletions(-)\n"))
        XCTAssertEqual(scaled[0].changes, 1000); XCTAssertNil(scaled[0].additions); XCTAssertNil(scaled[0].deletions)
        XCTAssertEqual(scaled[1].path, "path with spaces"); XCTAssertTrue(scaled[2].binary)
        for text in ["unexpected", "-1\t2\tfile", "1\t2\t", "future-json", "\(Int.max)\t1\tfile"] { XCTAssertNil(ReviewMaterialPresentation.files(text)) }
    }
    func testCommitSourceRetainsFullSHAAndUnknownFormatHasNoInventedIdentity() throws {
        let sha = String(repeating: "a", count: 40)
        let commits = try XCTUnwrap(ReviewMaterialPresentation.commits(sha + " Subject 👋\n"))
        XCTAssertEqual(commits[0].sha, sha); XCTAssertEqual(commits[0].subject, "Subject 👋")
        XCTAssertNil(ReviewMaterialPresentation.commits("abcdef short source"))
        XCTAssertNil(ReviewMaterialPresentation.commits("Unknown commit format"))
        var card = detail().task; XCTAssertNil(ReviewMaterialPresentation.conflictCount(card))
        card.bounceByReason = ["merge_conflict": 2]; XCTAssertEqual(ReviewMaterialPresentation.conflictCount(card), 2)
    }
}

@MainActor private final class ReviewTestClient: KabanClient {
    private let owner = UUID()
    var detail: TaskDetail
    let pipeline: PipelineSummary
    var sent: [CommandEnvelope] = []
    var refuse = false
    init(detail: TaskDetail, pipeline: PipelineSummary) { self.detail = detail; self.pipeline = pipeline }
    func getSnapshot() async throws -> Snapshot { Fix.snapshot(tasks: [detail.task], pipelines: [pipeline]) }
    func synchronize() async throws -> SnapshotReplacement { .init(snapshot: try await getSnapshot(), cursor: .init(sessionId: owner, offset: 0), current: []) }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { AsyncThrowingStream { $0.yield(.connection(.connected)) } }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { _ in } }
    func capabilities() async throws -> DaemonCapabilities { .init(operations: [.init(name: "synchronize", supported: true)], commands: [CommandName.getTaskDetail, .approve, .requestChanges, .reject].map { .init(name: $0.rawValue, support: .supported) }) }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if case .getTaskDetail = envelope.command { return .init(commandId: envelope.commandId, seq: nil, result: .taskDetail(detail)) }
        sent.append(envelope)
        if refuse {
            detail.artifacts[0].text = "Updated by another client"
            return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "invalid_state", message: "Review changed")))
        }
        return .init(commandId: envelope.commandId, seq: 11, result: .ok)
    }
}
