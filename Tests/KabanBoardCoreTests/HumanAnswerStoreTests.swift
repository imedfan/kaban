import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class HumanAnswerStoreTests: XCTestCase {
    private let question = HumanRequest(requestId: "q1", taskId: "t", runId: "r1", question: "Как обработать повтор?")
    private func detail(_ state: TaskState = .waitingHuman(.question), stage: String = "dev", request: HumanRequest? = nil) -> TaskDetail {
        .init(seq: 10, task: Fix.card("t", stage: stage, state: state), feed: [], runs: [], humanRequests: [request ?? question])
    }
    func testExactQuestionAndNotesExcludeIncidentDecision() throws {
        let context = try XCTUnwrap(HumanAnswerContext(detail: detail(), pipeline: Fix.pipeline()))
        let text = "**Сначала проверить**  \r\n👋"
        XCTAssertEqual(context.command(text: text, current: context), .answerHuman(taskId: "t", text: text, requestId: "q1"))
        XCTAssertNil(context.command(text: " \n", current: context)); XCTAssertNil(context.command(text: "a\0b", current: context))
        XCTAssertNil(HumanAnswerContext(detail: detail(.waitingHuman(.incident)), pipeline: Fix.pipeline()))
        for reason in WaitingHumanReason.allCases where reason != .question && reason != .incident {
            let note = try XCTUnwrap(HumanAnswerContext(detail: detail(.waitingHuman(reason)), pipeline: Fix.pipeline()))
            XCTAssertEqual(note.command(text: text, current: note), .answerHuman(taskId: "t", text: text, requestId: nil))
        }
    }
    func testNoAgentFieldInHumanGateMergeAndActiveRuns() {
        for kind in [StageKind.human, .gate, .merge, .queue, .terminal] {
            XCTAssertNil(HumanAnswerContext(detail: detail(), pipeline: Fix.pipeline([Fix.stage("dev", kind, order: 1)])))
        }
        for state in [TaskState.running, .gating, .paused, .queued(nil), .done, .cancelled] {
            XCTAssertNil(HumanAnswerContext(detail: detail(state), pipeline: Fix.pipeline()))
        }
        var missing = detail(); missing.humanRequests = []
        XCTAssertNil(HumanAnswerContext(detail: missing, pipeline: Fix.pipeline()))
        XCTAssertNil(HumanAnswerContext(detail: detail(), pipeline: nil))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CommandError(code: "test_timeout", message: "Answer session timeout")
    }
    @MainActor func testStaleRequestKeepsTextAfterReopenAndRequiresExplicitRetarget() async throws {
        let client = AnswerTestClient(detail: detail()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "test")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }; await session.select("t")
        let answers = HumanAnswerStore(session: session, storage: storage, key: "answers")
        answers.setText("Exact  \r\n👋", for: "t")
        client.detail.humanRequests = [.init(requestId: "q2", taskId: "t", runId: "r2", question: "Новый вопрос")]
        await session.retryDetail()
        let reopened = HumanAnswerStore(session: session, storage: storage, key: "answers")
        XCTAssertTrue(reopened.isStale("t")); XCTAssertFalse(reopened.canSubmit("t"))
        let staleSent = await reopened.submit("t"); XCTAssertFalse(staleSent); XCTAssertTrue(client.answers.isEmpty)
        XCTAssertEqual(reopened.draft(for: "t")?.context.request?.requestId, "q1")
        XCTAssertEqual(reopened.draft(for: "t")?.text, "Exact  \r\n👋")
        reopened.useTextForCurrentContext("t")
        XCTAssertEqual(reopened.draft(for: "t")?.context.request?.requestId, "q2")
        XCTAssertEqual(reopened.draft(for: "t")?.text, "Exact  \r\n👋"); XCTAssertTrue(reopened.canSubmit("t"))
    }
    @MainActor func testOKDoesNotClearDraftOrChangeCardAndCorrelationUnlocks() async throws {
        let client = AnswerTestClient(detail: detail()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "test")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }; await session.select("t")
        let answers = HumanAnswerStore(session: session, storage: storage, key: "answers")
        answers.setText("Answer", for: "t")
        let sent = await answers.submit("t"); XCTAssertTrue(sent)
        try await wait { session.canSend }
        XCTAssertEqual(answers.receipt(for: "t")?.phase, .awaitingEvent)
        XCTAssertEqual(session.projection?.tasks["t"]?.state, .waitingHuman(.question))
        XCTAssertEqual(answers.draft(for: "t")?.text, "Answer"); XCTAssertFalse(answers.canSubmit("t"))
        answers.setText("Double click", for: "t"); XCTAssertEqual(answers.draft(for: "t")?.text, "Answer")
        let duplicate = await answers.submit("t"); XCTAssertFalse(duplicate); XCTAssertEqual(Set(client.answers.map(\.commandId)).count, 1)
        var card = client.detail.task; card.state = .queued(nil)
        try session.consume(.event(Fix.envelope(11, .taskUpdated(card), commandId: client.answers[0].commandId)))
        XCTAssertEqual(answers.receipt(for: "t")?.phase, .applied)
        XCTAssertEqual(session.projection?.tasks["t"]?.state, .queued(nil))
    }
    @MainActor func testServerRefusalRefreshesQuestionAndPreservesInput() async throws {
        let client = AnswerTestClient(detail: detail()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "test")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }; await session.select("t")
        let answers = HumanAnswerStore(session: session, storage: storage, key: "answers")
        answers.setText("Old answer", for: "t")
        client.refuse = true
        let sent = await answers.submit("t"); XCTAssertFalse(sent)
        XCTAssertEqual(session.detail?.humanRequests.last?.requestId, "q2")
        XCTAssertNil(session.error, "Inline answer failure must not cover the refreshed question with a modal alert")
        XCTAssertTrue(answers.isStale("t")); XCTAssertEqual(answers.draft(for: "t")?.text, "Old answer")
        XCTAssertEqual(answers.draft(for: "t")?.context.request?.requestId, "q1")
    }
    @MainActor func testDisconnectedInputPersistsAndCannotSend() async throws {
        let client = AnswerTestClient(detail: detail()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "test")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }; await session.select("t")
        let answers = HumanAnswerStore(session: session, storage: storage, key: "answers")
        try session.consume(.connection(.reconnecting(lastSeq: 10)))
        answers.setText("Offline  \r\n", for: "t")
        XCTAssertFalse(answers.canSubmit("t")); let sent = await answers.submit("t"); XCTAssertFalse(sent)
        let reopened = HumanAnswerStore(session: session, storage: storage, key: "answers")
        XCTAssertEqual(reopened.draft(for: "t")?.text, "Offline  \r\n"); XCTAssertTrue(client.answers.isEmpty)
    }
    @MainActor func testMockAnswerIsIdempotentAndDoesNotAcceptSuspiciousSetOrChangeManualPriority() async throws {
        var card = Fix.card("t", state: .waitingHuman(.suspiciousFiles), files: [Fix.file(".env")])
        card.attempt = 3; card.maxAttempts = 3; card.runsSinceHuman = 12; card.priority = 7
        let client = MockKabanClient(snapshot: Fix.snapshot(tasks: [card]))
        let envelope = CommandEnvelope(command: .answerHuman(taskId: "t", text: "Убери .env", requestId: nil))
        let first = try await client.send(envelope), second = try await client.send(envelope)
        XCTAssertEqual(first, second)
        let snapshot = try await client.getSnapshot(), updated = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(updated.state, .queued(nil)); XCTAssertTrue(updated.suspiciousFiles.isEmpty)
        XCTAssertEqual(updated.maxAttempts, 4); XCTAssertEqual(updated.runsSinceHuman, 0)
        XCTAssertEqual(updated.attempt, 3); XCTAssertEqual(updated.priority, 7)
        let reply = try await client.send(.init(command: .getTaskDetail(taskId: "t")))
        guard case .taskDetail(let detail) = reply.result else { return XCTFail("Missing detail") }
        XCTAssertTrue(detail.acceptedFiles.isEmpty, "Clearing the current pending set does not accept its blobs")
        XCTAssertEqual(detail.feed.filter { $0.kind == "answer" }.map(\.text), ["Убери .env"])
    }
    @MainActor func testNotificationReplyCannotRetargetOrReplaceDraftAndWaitsForEvent() async throws {
        let client = AnswerTestClient(detail: detail()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "notification")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }; await session.select("t")
        let answers = HumanAnswerStore(session: session, storage: storage, key: "answers")
        XCTAssertNotNil(answers.prepareNotificationReply("Reply", for: "t", requestID: "old"))
        XCTAssertTrue(client.answers.isEmpty); XCTAssertEqual(answers.draft(for: "t")?.text, "")
        answers.setText("Panel draft", for: "t")
        XCTAssertNotNil(answers.prepareNotificationReply("Reply", for: "t", requestID: "q1"))
        XCTAssertEqual(answers.draft(for: "t")?.text, "Panel draft")
        answers.setText("", for: "t")
        XCTAssertNil(answers.prepareNotificationReply("Reply", for: "t", requestID: "q1"))
        let sent = await answers.submit("t"); XCTAssertTrue(sent)
        XCTAssertEqual(client.answers.first?.command, .answerHuman(taskId: "t", text: "Reply", requestId: "q1"))
        XCTAssertNotNil(answers.prepareNotificationReply("Duplicate", for: "t", requestID: "q1"))
        XCTAssertEqual(client.answers.count, 1); XCTAssertEqual(answers.draft(for: "t")?.text, "Reply")
        XCTAssertEqual(answers.receipt(for: "t")?.phase, .awaitingEvent)
    }
    @MainActor func testCorruptDraftStorageBlocksSendingWithoutOverwritingIt() {
        let storage = MemoryKeyValueStore(); storage.set(Data("bad".utf8), forKey: "answers")
        let session = BoardSession(client: AnswerTestClient(detail: detail()), storage: storage, key: "test")
        let answers = HumanAnswerStore(session: session, storage: storage, key: "answers")
        XCTAssertNotNil(answers.storageError); XCTAssertFalse(answers.canSubmit("t"))
        XCTAssertEqual(storage.data(forKey: "answers"), Data("bad".utf8))
    }
}

@MainActor private final class AnswerTestClient: KabanClient {
    private let sessionID = UUID()
    var detail: TaskDetail
    var answers: [CommandEnvelope] = []
    var refuse = false
    init(detail: TaskDetail) { self.detail = detail }
    func getSnapshot() async throws -> Snapshot { Fix.snapshot(tasks: [detail.task]) }
    func synchronize() async throws -> SnapshotReplacement {
        .init(snapshot: try await getSnapshot(), cursor: .init(sessionId: sessionID, offset: 0), current: [])
    }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> {
        AsyncThrowingStream { $0.yield(.connection(.connected)) }
    }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { _ in } }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: [.init(name: "synchronize", supported: true)], commands: [.init(name: "getTaskDetail", support: .supported), .init(name: "answerHuman", support: .supported)])
    }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if case .getTaskDetail = envelope.command { return .init(commandId: envelope.commandId, seq: nil, result: .taskDetail(detail)) }
        answers.append(envelope)
        if refuse {
            detail.humanRequests = [.init(requestId: "q2", taskId: "t", runId: "r2", question: "Новый вопрос")]
            return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "invalid_state", message: "Вопрос уже закрыт.")))
        }
        return .init(commandId: envelope.commandId, seq: 11, result: .ok)
    }
}
