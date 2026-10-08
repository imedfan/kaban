import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class PipelineEditorTests: XCTestCase {
    let yaml = "# keep 👋\r\nversion: 1\r\nunknown: {custom: yes}\r\nboard: {max_waiting_human: 3, future: 9} # note\r\nstages:\r\n  - id: dev\r\n    kind: agent\r\n    agent: {model: explicit, skill: '.kaban/skills/dev.md', future: x}\r\n    gates:\r\n      - \"echo value: one\"\r\n    retry: {max_attempts: 3, backoff: [30s, 2m]}\r\n    on_success: done\r\n  # separator\r\n  - {id: done, kind: terminal} # future\r\n"
    func testFormsPatchOnlyTargetAndKeepCRLFUnicodeCommentsAndUnknownFields() throws {
        let document = PipelineTextDocument(yaml)
        XCTAssertTrue(document.supportsForms)
        XCTAssertEqual(document.stages.map(\.id), ["dev", "done"])
        XCTAssertEqual(try document.replacing("stages[0].agent.model", with: "another", quoted: true), yaml.replacingOccurrences(of: "model: explicit", with: "model: \"another\""))
        XCTAssertEqual(try document.replacing("board.max_waiting_human", with: "7"), yaml.replacingOccurrences(of: "max_waiting_human: 3", with: "max_waiting_human: 7"))
        let inserted = try document.replacing("stages[0].display.order", with: "8")
        XCTAssertTrue(inserted.contains("    display:\r\n      order: 8\r\n"))
        XCTAssertTrue(inserted.contains("future: x}")); XCTAssertTrue(inserted.contains("# separator\r\n"))
        XCTAssertEqual(PipelineTextDocument(inserted).value("stages[0].display.order"), "8")
        let flow = try document.replacing("stages[1].display.order", with: "9")
        XCTAssertTrue(flow.contains("kind: terminal, display: {order: 9}} # future"))
    }
    func testComplexAndDuplicateMappingsRemainAvailableOnlyAsExactYAML() throws {
        for text in ["stages: &stage\n  - id: dev\n    kind: agent\n", "defaults: &d {kind: agent}\nstages:\n  - <<: *d\n    id: dev\n", "%YAML 1.2\n---\nstages: []\n"] {
            let doc = PipelineTextDocument(text)
            XCTAssertFalse(doc.supportsForms); XCTAssertThrowsError(try doc.replacing("version", with: "1"))
        }
        let duplicate = PipelineTextDocument("board:\n  max_waiting_human: 3\n  max_waiting_human: 5\n")
        XCTAssertFalse(duplicate.canEdit("board.max_waiting_human"))
        XCTAssertThrowsError(try duplicate.replacing("board.max_waiting_human", with: "6"))
        XCTAssertFalse(PipelineTextDocument("stages:\n  - id: dev\n    kind: agent\n").canEdit("stages[0].returns_to[0].stage"))
        let returns = "stages:\n  - {id: test, kind: agent, returns_to: [{stage: dev, future: x}]}\n"
        let patched = try PipelineTextDocument(returns).replacing("stages[0].returns_to[0].limit", with: "3")
        XCTAssertEqual(patched, returns.replacingOccurrences(of: "future: x}", with: "future: x, limit: 3}"))
    }
    func testValidationMessageTranslationUsesServerBoundsAndFallback() {
        let issue = ValidationIssue(path: "stages[0].timeouts.stall", code: "duration_out_of_range", message: "server", severity: .error,
                                    params: ["label": "stall", "min": "1m", "max": "30m"])
        XCTAssertEqual(ValidationIssueText.render(issue), "Таймаут зависания должен быть от 1 мин до 30 мин")
        var legacy = issue; legacy.params = [:]
        XCTAssertEqual(ValidationIssueText.render(legacy), "server")
        legacy.code = "future"; legacy.message = "Exact {path}"
        XCTAssertEqual(ValidationIssueText.render(legacy), "Exact {path}")
        XCTAssertEqual(ValidationIssueText.duration("1h"), "1 ч")
        XCTAssertEqual(ValidationIssueText.duration("1h30m"), "1h30m")
    }
    func testAddRemovePreservesOtherStagesAndDoesNotRewriteGraph() throws {
        let source = "stages:\n  - id: a\n    kind: agent\n    on_success: b\n  # belongs to b\n  - id: b\n    kind: terminal\n"
        let doc = PipelineTextDocument(source)
        XCTAssertEqual(try doc.removingStage(index: 0), "stages:\n  # belongs to b\n  - id: b\n    kind: terminal\n")
        let added = try doc.addingStage(id: "check", kind: "gate")
        XCTAssertTrue(added.hasPrefix(source)); XCTAssertTrue(added.contains("    on_success: b\n"))
    }
    private func fileSource(_ text: String?) throws -> PipelineSourceContent {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".kaban/pipeline.yaml")
        if let text { try Data(text.utf8).write(to: path) }
        return .init(projectId: Fix.project, path: path.path, baseVersionHash: "v1", baseSourceHash: "s1", committedContent: text, workingContent: text, worktreeSourceHash: "s1")
    }
    func testWriterRejectsExternalChangeMissingAndSymlinkAndKeepsExactBytes() throws {
        let source = try fileSource(yaml), url = URL(fileURLWithPath: source.path)
        try PipelineFileWriter.write("exact  \r\n👋\n", source: source)
        XCTAssertEqual(try Data(contentsOf: url), Data("exact  \r\n👋\n".utf8))
        XCTAssertThrowsError(try PipelineFileWriter.write("second", source: source))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "exact  \r\n👋\n")
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try PipelineFileWriter.write("missing", source: source))
        let outside = url.deletingLastPathComponent().appendingPathComponent("outside")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        XCTAssertThrowsError(try PipelineFileWriter.write("overwrite", source: source))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
        let absent = try fileSource(nil)
        try PipelineFileWriter.write("", source: absent)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: absent.path)), Data())
        XCTAssertThrowsError(try PipelineFileWriter.write("late", source: absent))
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CommandError(code: "timeout", message: "Pipeline test timed out")
    }
    @MainActor func testValidationErrorsWarningsOldHashAndUnavailablePreserveDraft() async throws {
        let client = EditorTestClient(source: try fileSource(yaml)), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "pipeline-test")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let editor = PipelineEditorStore(projectID: Fix.project, client: client, session: session)
        await editor.readSource(); XCTAssertTrue(editor.canApply)
        editor.edit(yaml + "# é", debounce: false)
        let composedHash = editor.draft?.contentHash
        editor.edit(yaml + "# e\u{301}", debounce: false)
        XCTAssertNotEqual(editor.draft?.contentHash, composedHash)
        XCTAssertTrue(editor.content.utf8.elementsEqual((yaml + "# e\u{301}").utf8))
        await editor.validate()
        client.issues = [.init(path: "board", code: "future", message: "Server message", severity: .error)]
        await editor.validate(); XCTAssertFalse(editor.canApply)
        client.issues[0].severity = .warning; await editor.validate(); XCTAssertTrue(editor.canApply)
        client.held = true
        editor.edit(yaml + "# A", debounce: false)
        let first = Task { await editor.validate() }
        try await wait { client.waiters.count == 1 }
        editor.edit(yaml + "# B", debounce: false)
        let second = Task { await editor.validate() }
        try await wait { client.waiters.count == 2 }
        client.resolve(1, issues: [])
        await second.value; XCTAssertTrue(editor.canApply)
        client.resolve(0, issues: [.init(path: "", code: "old", message: "Old error", severity: .error)])
        await first.value; XCTAssertTrue(editor.canApply); XCTAssertEqual(editor.content, yaml + "# B")
        client.held = false; client.wrongProject = true
        await editor.validate(); XCTAssertFalse(editor.canApply); XCTAssertEqual(editor.content, yaml + "# B")
        XCTAssertTrue(session.journal?.records.isEmpty == true)
    }
    @MainActor func testApplyWaitsForCorrelatedEventAndDoesNotMarkLaterEditsSaved() async throws {
        let client = EditorTestClient(source: try fileSource(yaml)), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "pipeline-test")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let editor = PipelineEditorStore(projectID: Fix.project, client: client, session: session)
        await editor.readSource(); editor.edit(yaml + "# draft\n", debounce: false); await editor.validate()
        await editor.apply()
        XCTAssertEqual(editor.receipt?.phase, .awaitingEvent); XCTAssertFalse(editor.isApplied); XCTAssertFalse(editor.canApply)
        await editor.apply(); XCTAssertEqual(client.applied.count, 1)
        let sent = try XCTUnwrap(client.applied.first)
        guard case .updatePipeline(_, _, let draft) = sent.command else { return XCTFail() }
        XCTAssertEqual(draft?.content, yaml + "# draft\n"); XCTAssertEqual(draft?.requiresExactWorkingContent, true)
        editor.edit(yaml + "# later\n", debounce: false)
        var summary = client.pipeline; summary.versionHash = "v2"; summary.sourceHash = "s2"
        try session.consume(.event(Fix.envelope(11, .pipelineApplied(summary), commandId: sent.commandId)))
        client.source.baseVersionHash = "v2"; client.source.baseSourceHash = "s2"; client.source.committedContent = draft?.content
        await editor.confirmApplied()
        XCTAssertTrue(editor.isApplied); XCTAssertTrue(editor.hasDraftChanges)
        XCTAssertEqual(editor.content, yaml + "# later\n")
    }
    @MainActor func testRaceAndBackendRefusalNeverRollBackLaterExternalBytes() async throws {
        let client = EditorTestClient(source: try fileSource(yaml)), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "pipeline-test")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let editor = PipelineEditorStore(projectID: Fix.project, client: client, session: session)
        await editor.readSource(); editor.edit(yaml + "# mine\n", debounce: false); await editor.validate()
        try "external\n".write(toFile: client.source.path, atomically: true, encoding: .utf8)
        await editor.apply(); XCTAssertEqual(client.applied.count, 0); XCTAssertNotNil(editor.changedSource)
        XCTAssertEqual(editor.content, yaml + "# mine\n")
        await editor.keepDraftOnChangedSource(); XCTAssertTrue(editor.canApply)
        client.refuseWithExternalEdit = true; await editor.apply()
        XCTAssertEqual(editor.receipt?.phase, .rejected(.init(code: "git_race", message: "Late edit")))
        XCTAssertEqual(try String(contentsOfFile: client.source.path, encoding: .utf8), "late external\n")
        XCTAssertEqual(editor.content, yaml + "# mine\n"); XCTAssertEqual(session.projection?.pipelines[Fix.project]?.versionHash, "v1")
    }
}

@MainActor private final class EditorTestClient: KabanClient {
    var source: PipelineSourceContent
    var pipeline: PipelineSummary
    var held = false, wrongProject = false, refuseWithExternalEdit = false
    var issues: [ValidationIssue] = []
    var applied: [CommandEnvelope] = []
    var waiters: [(CommandEnvelope, CheckedContinuation<CommandReply, Never>)] = []
    init(source: PipelineSourceContent) {
        self.source = source; pipeline = Fix.pipeline(); pipeline.sourceHash = source.baseSourceHash
    }
    func getSnapshot() async throws -> Snapshot {
        var project = Fix.project(); project.path = URL(fileURLWithPath: source.path).deletingLastPathComponent().deletingLastPathComponent().path
        return Fix.snapshot(projects: [project], pipelines: [pipeline])
    }
    func synchronize() async throws -> SnapshotReplacement { .init(snapshot: try await getSnapshot(), cursor: .init(sessionId: UUID(), offset: 0), current: []) }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { AsyncThrowingStream { $0.yield(.connection(.connected)) } }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { _ in } }
    func capabilities() async throws -> DaemonCapabilities { .init(operations: [.init(name: "synchronize", supported: true)], commands: [CommandName.getPipelineSource, .validatePipelineDraft, .updatePipeline].map { .init(name: $0.rawValue, support: .supported) }) }
    func resolve(_ index: Int, issues: [ValidationIssue]) { waiters[index].1.resume(returning: validation(waiters[index].0, issues: issues)) }
    private func validation(_ envelope: CommandEnvelope, issues: [ValidationIssue]) -> CommandReply {
        guard case .validatePipelineDraft(let draft) = envelope.command else { fatalError() }
        return .init(commandId: envelope.commandId, seq: nil, result: .pipelineDraft(.init(projectId: wrongProject ? Fix.other : draft.projectId, contentHash: draft.contentHash, issues: issues, resolved: pipeline, baseVersionHash: draft.baseVersionHash, baseSourceHash: draft.baseSourceHash)))
    }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        switch envelope.command {
        case .getPipelineSource:
            var fresh = source; fresh.workingContent = try String(contentsOfFile: source.path, encoding: .utf8)
            if fresh.workingContent != source.workingContent { fresh.worktreeSourceHash = PipelineContentHash.sha256(fresh.workingContent!) }
            return .init(commandId: envelope.commandId, seq: nil, result: .pipelineSource(fresh))
        case .validatePipelineDraft:
            if held { return await withCheckedContinuation { waiters.append((envelope, $0)) } }
            return validation(envelope, issues: issues)
        case .updatePipeline:
            applied.append(envelope)
            if refuseWithExternalEdit {
                try "late external\n".write(toFile: source.path, atomically: true, encoding: .utf8)
                return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "git_race", message: "Late edit")))
            }
            return .init(commandId: envelope.commandId, seq: 11, result: .ok)
        default: return .init(commandId: envelope.commandId, seq: nil, result: .ok)
        }
    }
}
