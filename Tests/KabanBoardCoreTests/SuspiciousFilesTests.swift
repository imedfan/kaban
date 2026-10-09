import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class SuspiciousFilesTests: XCTestCase {
    private func detail(_ kind: StageKind = .gate, blob: String = "old") -> (TaskDetail, PipelineSummary) {
        var source = Fix.stage("checks", kind, order: 3, onSuccess: "done")
        if kind == .gate { source.onFail = .init(stage: "dev", limit: 3) }
        if kind == .merge { source.onConflict = .init(stage: "dev", limit: 2) }
        var readOnly = Fix.stage("ai", .agent, order: 2, onSuccess: "checks"); readOnly.readOnly = true
        let pipeline = Fix.pipeline([Fix.stage("backlog", .queue, order: 0, onSuccess: "dev"),
                                     Fix.stage("dev", .agent, order: 1, onSuccess: "ai"), readOnly, source, Fix.stage("done", .terminal, order: 4)])
        let file = SuspiciousFile(path: "api/.env 👋", rule: .pattern, pattern: ".env*", sizeBytes: 12, isText: true, blob: blob)
        let card = Fix.card("t", stage: "checks", state: .waitingHuman(.suspiciousFiles), files: [file])
        return (.init(seq: 10, task: card, feed: [], runs: [], suspiciousFiles: [file],
                      fileCheck: .init(maxFileBytes: 100, includesUncommitted: false, baseCommit: nil, returnPipeline: pipeline)), pipeline)
    }
    func testStageSpecificReturnPreservesExactCommentsAndServerDefault() throws {
        for kind in [StageKind.gate, .merge] {
            let (value, pipeline) = detail(kind)
            let context = try XCTUnwrap(SuspiciousFilesContext(detail: value, pipeline: pipeline))
            XCTAssertEqual(context.targets.map(\.id), ["dev"]); XCTAssertEqual(context.defaultTarget, "dev")
            XCTAssertEqual(context.returnCommand(current: context, comments: " \n", target: "dev"), .moveTask(taskId: "t", stage: "dev"))
            XCTAssertEqual(context.returnCommand(current: context, comments: "Exact  \r\n👋", target: "dev"), .requestChanges(taskId: "t", comments: "Exact  \r\n👋", target: "dev"))
            XCTAssertNil(context.returnCommand(current: context, comments: "comment", target: "ai"))
            XCTAssertNil(context.returnCommand(current: context, comments: "comment", target: nil))
            XCTAssertNil(HumanAnswerContext(detail: value, pipeline: pipeline))
            var changed = value; changed.suspiciousFiles[0].blob = "new"; changed.task.suspiciousFiles = changed.suspiciousFiles
            XCTAssertNil(context.returnCommand(current: .init(detail: changed, pipeline: pipeline), comments: "comment", target: "dev"))
        }
        let (agent, pipeline) = detail(.agent)
        let context = try XCTUnwrap(SuspiciousFilesContext(detail: agent, pipeline: pipeline))
        XCTAssertFalse(context.canReturn); XCTAssertNil(context.returnCommand(current: context, comments: "comment", target: "dev"))
        XCTAssertNotNil(HumanAnswerContext(detail: agent, pipeline: pipeline))
    }
    func testPreviewRequiresKnownThresholdAndTextBelowIt() {
        let file = detail().0.suspiciousFiles[0]
        XCTAssertFalse(SuspiciousFilesContext.canPreview(file, check: nil))
        XCTAssertFalse(SuspiciousFilesContext.canPreview(file, check: .init(maxFileBytes: 12, includesUncommitted: false, baseCommit: nil)))
        XCTAssertTrue(SuspiciousFilesContext.canPreview(file, check: .init(maxFileBytes: 13, includesUncommitted: true, baseCommit: "base")))
        var binary = file; binary.isText = false
        XCTAssertFalse(SuspiciousFilesContext.canPreview(binary, check: .init(maxFileBytes: 100, includesUncommitted: false, baseCommit: nil)))
    }
    func testReturnUsesTheTaskFrozenPipelineAfterTheProjectChanges() throws {
        let (original, frozen) = detail()
        var value = original
        value.fileCheck = .init(maxFileBytes: 100, includesUncommitted: false, baseCommit: nil, returnPipeline: frozen)
        var edited = frozen
        edited.stages[1].readOnly = true
        edited.stages[3].onFail = .init(stage: "ai", limit: 2)
        let context = try XCTUnwrap(SuspiciousFilesContext(detail: value, pipeline: edited))
        XCTAssertEqual(context.targets.map(\.id), ["dev"])
        XCTAssertEqual(context.defaultTarget, "dev")
        XCTAssertEqual(context.pipeline, frozen)
        value.fileCheck = nil
        let legacy = try XCTUnwrap(SuspiciousFilesContext(detail: value, pipeline: edited))
        XCTAssertFalse(legacy.canReturn)
        XCTAssertNil(legacy.defaultTarget)
        let (agent, agentPipeline) = detail(.agent)
        var changedKind = agentPipeline
        changedKind.stages[3].kind = .merge
        XCTAssertNotNil(HumanAnswerContext(detail: agent, pipeline: changedKind))
    }
    func testOnlyTheAcceptedCardConfirmsAcceptance() {
        let card = detail().0.task
        let command = Command.acceptSuspiciousFiles(taskId: card.id, files: [.init(path: "api/.env 👋", blob: "old")])
        XCTAssertFalse(command.isConfirmed(by: .taskUpdated(card)))
        var accepted = card; accepted.suspiciousFiles = []; accepted.state = .gating
        XCTAssertTrue(command.isConfirmed(by: .taskUpdated(accepted)))
        accepted.id = "other"; XCTAssertFalse(command.isConfirmed(by: .taskUpdated(accepted)))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CommandError(code: "test_timeout", message: "File session timeout")
    }
    @MainActor func testStaleRefreshDoesNotResubmitAndOKKeepsPending() async throws {
        let (value, pipeline) = detail(), client = FilesTestClient(detail: value, pipeline: pipeline)
        let storage = MemoryKeyValueStore(), session = BoardSession(client: client, storage: storage, key: "files")
        let loop = Task { await session.run() }; defer { loop.cancel(); session.stop() }
        try await wait { session.canSend }; await session.select("t")
        let files = SuspiciousFilesStore(session: session, storage: storage, key: "return")
        let original = try XCTUnwrap(files.context(for: "t"))
        client.refuse = true
        await files.accept(original)
        XCTAssertEqual(files.staleFiles(for: "t")?.first?.blob, "old")
        XCTAssertEqual(session.detail?.suspiciousFiles.first?.blob, "new")
        XCTAssertEqual(client.commands.count, 1); XCTAssertFalse(files.canAccept(original)); XCTAssertNil(session.error)
        try await wait { files.context(for: "t")?.files.first?.blob == "new" && session.canSend }
        let current = try XCTUnwrap(files.context(for: "t"))
        client.refuse = false; await files.accept(current)
        try await wait { session.canSend }
        XCTAssertEqual(Set(client.commands.map(\.commandId)).count, 2); XCTAssertEqual(files.acceptance(for: "t")?.phase, .awaitingEvent)
        XCTAssertEqual(session.projection?.tasks["t"]?.state, .waitingHuman(.suspiciousFiles))
        await files.accept(current); XCTAssertEqual(Set(client.commands.map(\.commandId)).count, 2)
    }
    @MainActor func testReturnDraftReopensAndCannotTargetChangedFilesWithoutExplicitAction() async throws {
        let (value, pipeline) = detail(), client = FilesTestClient(detail: value, pipeline: pipeline)
        let storage = MemoryKeyValueStore(), session = BoardSession(client: client, storage: storage, key: "files")
        let loop = Task { await session.run() }; defer { loop.cancel(); session.stop() }
        try await wait { session.canSend }; await session.select("t")
        let files = SuspiciousFilesStore(session: session, storage: storage, key: "return")
        files.edit("t", comments: "Keep  \r\n👋", target: "dev")
        client.detail.suspiciousFiles[0].blob = "new"; client.detail.task.suspiciousFiles = client.detail.suspiciousFiles
        client.detail.seq += 1
        try session.consume(.event(Fix.envelope(client.detail.seq, .taskUpdated(client.detail.task))))
        await session.retryDetail()
        let reopened = SuspiciousFilesStore(session: session, storage: storage, key: "return")
        XCTAssertEqual(reopened.draft(for: "t")?.comments, "Keep  \r\n👋"); XCTAssertFalse(reopened.canReturn("t"))
        reopened.useCurrent("t")
        XCTAssertEqual(reopened.command(for: "t"), .requestChanges(taskId: "t", comments: "Keep  \r\n👋", target: "dev"))
        try session.consume(.connection(.reconnecting(lastSeq: 10))); XCTAssertFalse(reopened.canReturn("t"))
    }
    @MainActor func testMockAcceptsExactSetOnceAndRejectsStale() async throws {
        let (value, pipeline) = detail(.agent)
        let mock = MockKabanClient(snapshot: Fix.snapshot(tasks: [value.task], pipelines: [pipeline]))
        let stale = try await mock.send(.init(command: .acceptSuspiciousFiles(taskId: "t", files: [.init(path: "api/.env 👋", blob: "wrong")])))
        guard case .error(let error) = stale.result else { return XCTFail() }; XCTAssertEqual(error.code, CommandError.staleSuspiciousFilesCode)
        let command = CommandEnvelope(command: .acceptSuspiciousFiles(taskId: "t", files: value.suspiciousFiles.map { .init(path: $0.path, blob: $0.blob) }))
        let first = try await mock.send(command), replay = try await mock.send(command); XCTAssertEqual(first, replay)
        guard case .taskDetail(let result) = try await mock.send(.init(command: .getTaskDetail(taskId: "t"))).result else { return XCTFail() }
        XCTAssertEqual(result.task.state, .done); XCTAssertEqual(result.acceptedFiles.count, 1); XCTAssertEqual(result.acceptedFiles.first?.blob, "old")
    }
    func testFileAccessRejectsTraversalSymlinksDirectoriesAndMissingClone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "nested/file 👋.txt"
        try "test".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        XCTAssertEqual(try TaskFileAccess.validate(clonePath: root.path, relativePath: path).size, 4)
        for value in ["../outside", "/etc/passwd", "nested/../file", "nested", "nested//file", "missing", "a\0b"] {
            XCTAssertThrowsError(try TaskFileAccess.validate(clonePath: root.path, relativePath: value), value)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent(path))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir-link"), withDestinationURL: root.appendingPathComponent("nested"))
        XCTAssertThrowsError(try TaskFileAccess.validate(clonePath: root.path, relativePath: "link"))
        XCTAssertThrowsError(try TaskFileAccess.validate(clonePath: root.path, relativePath: "dir-link/file 👋.txt"))
        XCTAssertThrowsError(try TaskFileAccess.validate(clonePath: nil, relativePath: path))
    }
}

@MainActor private final class FilesTestClient: KabanClient {
    var detail: TaskDetail
    let pipeline: PipelineSummary
    var refuse = false
    var commands: [CommandEnvelope] = []
    private let sessionID = UUID()
    init(detail: TaskDetail, pipeline: PipelineSummary) { self.detail = detail; self.pipeline = pipeline }
    func getSnapshot() async throws -> Snapshot { Fix.snapshot(seq: detail.seq, tasks: [detail.task], pipelines: [pipeline]) }
    func synchronize() async throws -> SnapshotReplacement { .init(snapshot: try await getSnapshot(), cursor: .init(sessionId: sessionID, offset: 0), current: []) }
    private var continuation: AsyncThrowingStream<KabanClientUpdate, Error>.Continuation?
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { .init { continuation = $0; $0.yield(.connection(.connected)) } }
    func events() -> AsyncStream<EventEnvelope> { .init { _ in } }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: ["snapshot", "command", "subscribe", "synchronize"].map { .init(name: $0, supported: true) },
              commands: CommandName.allCases.map { .init(name: $0.rawValue, support: .supported) })
    }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if case .getTaskDetail = envelope.command { return .init(commandId: envelope.commandId, seq: nil, result: .taskDetail(detail)) }
        commands.append(envelope)
        if refuse {
            detail.suspiciousFiles[0].blob = "new"; detail.task.suspiciousFiles = detail.suspiciousFiles
            detail.seq += 1
            continuation?.yield(.event(Fix.envelope(detail.seq, .taskUpdated(detail.task))))
            return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: CommandError.staleSuspiciousFilesCode, message: "Changed")))
        }
        return .init(commandId: envelope.commandId, seq: nil, result: .ok)
    }
}
