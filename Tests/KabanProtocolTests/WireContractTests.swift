import Foundation
import XCTest
import KabanProtocol
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Successful payloads describe the contract, not the current backend's capability set.
struct WireContractExample: Codable, Equatable {
    var name: String
    var request: DaemonRequest
    var response: DaemonResponse
    var journal: EventEnvelope?
    var live: EphemeralEnvelope?
    var refusal: DaemonResponse
}
enum WireContractExamples {
    static let cursor = EphemeralCursor(sessionId: UUID(uuidString: "6F1C2B9E-6C1A-4C2E-9E0B-7A2F7B0C1D02")!, offset: 1)
    static let draft = PipelineDraft(projectId: Samples.project, baseVersionHash: "sha256:9f2c", content: """
    version: 1
    stages:
      - {id: backlog, name: Backlog, kind: queue, on_success: dev}
      - id: dev
        name: Dev
        kind: agent
        wip: 3
        agent: {model: explicit-model, skill: dev.md}
        on_success: review
      - {id: review, name: Review, kind: human, wip: 5, on_success: merge}
      - {id: merge, name: Merge, kind: merge, wip: 1, on_success: done}
      - {id: done, name: Done, kind: terminal}
    """)
    static let appliedPipeline = PipelineSummary(projectId: Samples.project, versionHash: draft.contentHash,
        gitPreset: .standard, stages: [
            .init(id: "backlog", name: "Backlog", kind: .queue, display: .init(order: 0), onSuccess: "dev"),
            .init(id: "dev", name: "Dev", kind: .agent, display: .init(order: 1), wip: 3, model: "explicit-model", onSuccess: "review"),
            .init(id: "review", name: "Review", kind: .human, display: .init(order: 2), wip: 5, onSuccess: "merge"),
            .init(id: "merge", name: "Merge", kind: .merge, display: .init(order: 3), wip: 1, onSuccess: "done", onConflict: .init(stage: "dev", limit: 2)),
            .init(id: "done", name: "Done", kind: .terminal, display: .init(order: 4))
        ], defaultReturnStage: "dev")
    static let snapshot = Snapshot(seq: Samples.snapshot.seq, projects: [Samples.snapshot.projects[0]],
                                   pipelines: [Samples.pipeline], tasks: [Samples.tasks[0]])
    static let environment = CursorEnvironment(executablePath: "/usr/local/bin/cursor-agent")
    static let restore = WIPRestore(taskId: "t-1", runId: "r-11", wipRef: "refs/kaban/wip/r-11")
    static let validation: PipelineDraftValidation = {
        var resolved = appliedPipeline; resolved.versionHash = nil
        return .init(projectId: Samples.project, contentHash: draft.contentHash, issues: [], resolved: resolved,
                     baseVersionHash: draft.baseVersionHash)
    }()
    static let progress = EphemeralEnvelope(cursor: cursor, afterSeq: Samples.snapshot.seq, at: Samples.t0,
        event: .runProgress(.init(runId: "r-11", taskId: "t-1", message: "Проверяю", lastActivityAt: Samples.t0)))
    static let connections: [DaemonConnectionState] = [
        .connecting, .synchronizing, .connected, .reconnecting(lastSeq: 1042),
        .disconnected(.init(code: "transport_failure", message: "Соединение прервано"))
    ]
    static func command(_ name: String, _ command: Command, result: CommandResult, journal: JournalEvent? = nil,
                        live: EphemeralEvent? = nil, error: String = CommandError.unsupportedCommandCode) -> WireContractExample {
        .init(name: name, request: .init(.command(.init(commandId: Samples.cmd, command: command))),
              response: .init(.command(.init(commandId: Samples.cmd, seq: journal == nil ? nil : 1043, result: result))),
              journal: journal.map { event in
                  let project: ProjectID? = { if case .cursorEnvironmentChanged = event { return nil }; return Samples.project }()
                  return .init(seq: 1043, at: Samples.t0, projectId: project, commandId: Samples.cmd, event: event)
              },
              live: live.map { .init(cursor: cursor, afterSeq: 1042, at: Samples.t0, event: $0) },
              refusal: .init(.command(.init(commandId: Samples.cmd, seq: nil, result: .error(.init(code: error, message: "Операция отклонена"))))))
    }
    static let values: [WireContractExample] = [
        .init(name: "capabilities", request: .init(.capabilities),
              response: .init(.capabilities(.init(operations: [.init(name: "readLog", supported: false)],
                 commands: [.init(name: "createTask", support: .managedFakeOnly), .init(name: "restoreWIP", support: .unsupported)]))),
              refusal: .init(.error(.init(code: CommandError.protocolMismatchCode, message: "Несовместимая версия")))),
        .init(name: "synchronize", request: .init(.synchronize),
              response: .init(.replacement(.init(snapshot: snapshot, cursor: cursor, current: [progress]))),
              live: progress, refusal: .init(.error(.init(code: "incomplete_projection", message: "Неполная проекция")))),
        .init(name: "ephemeral", request: .init(.ephemeral(after: .init(sessionId: cursor.sessionId, offset: 0), limit: 1)),
              response: .init(.ephemeral(.init(fromCursor: .init(sessionId: cursor.sessionId, offset: 0), nextCursor: cursor,
                                              latestCursor: cursor, events: [progress]))),
              live: progress, refusal: .init(.error(.init(code: "invalid_request", message: "Некорректный курсор")))),
        .init(name: "readLog", request: .init(.readLog(runId: "r-11", fromOffset: 0, limit: 1)),
              response: .init(.log(.init(batch: .init(runId: "r-11", fromOffset: 0, nextOffset: 1,
                                                     events: [.message(role: "assistant", text: "Готово")]),
                                        availableFromOffset: 0, endOffset: 1, isComplete: true))),
              refusal: .init(.error(.init(code: CommandError.logUnavailableCode, message: "Лог недоступен")))),
        command("validatePipelineDraft", .validatePipelineDraft(draft: draft), result: .pipelineDraft(validation),
                live: .pipelineDraftValidated(validation), error: CommandError.stalePipelineDraftCode),
        command("updatePipeline", .updatePipeline(projectId: Samples.project, contentHash: draft.contentHash, draft: draft),
                result: .pipelineVersion(hash: draft.contentHash), journal: .pipelineApplied(appliedPipeline), error: CommandError.pipelineHashMismatchCode),
        command("getCursorEnvironment", .getCursorEnvironment, result: .cursorEnvironment(environment)),
        command("configureCursor", .configureCursor(environment: environment), result: .ok, journal: .cursorEnvironmentChanged(environment)),
        command("restoreWIP", .restoreWIP(taskId: restore.taskId, runId: restore.runId, wipRef: restore.wipRef), result: .ok, journal: .wipRestored(restore))
    ]
}

final class WireContractTests: XCTestCase {
    func testLegacyUpdateHasNoDraftAndKnownMalformedDraftIsRejected() throws {
        let data = Data(#"{"updatePipeline":{"projectId":"p","contentHash":"h","future":true}}"#.utf8)
        XCTAssertEqual(try KabanCoding.makeDecoder().decode(Command.self, from: data), .updatePipeline(projectId: "p", contentHash: "h"))
        XCTAssertThrowsError(try KabanCoding.makeDecoder().decode(Command.self,
            from: Data(#"{"updatePipeline":{"projectId":"p","contentHash":"h","draft":"malformed"}}"#.utf8)))
    }
    func testSHA256StandardVectorsAndExactUTF8() {
        XCTAssertEqual(PipelineContentHash.sha256(""), "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(PipelineContentHash.sha256("abc"), "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(PipelineContentHash.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "sha256:248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertNotEqual(PipelineContentHash.sha256("version: 1\n"), PipelineContentHash.sha256("version: 1\r\n"))
        #if canImport(CryptoKit)
        for length in [1, 55, 56, 63, 64, 65, 127, 128, 129, 4096] {
            let text = String(repeating: "ё🦊", count: length)
            let reference = "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(PipelineContentHash.sha256(text), reference)
        }
        #endif
    }
    func testDraftBindingRejectsOtherProjectVersionHashAndChangedText() throws {
        let draft = WireContractExamples.draft
        try draft.checkBinding(projectId: draft.projectId, currentVersionHash: draft.baseVersionHash, requestedHash: draft.contentHash)
        for (project, version, hash, code) in [
            (ProjectID(rawValue: "other"), draft.baseVersionHash, draft.contentHash, CommandError.stalePipelineDraftCode),
            (draft.projectId, "new", draft.contentHash, CommandError.stalePipelineDraftCode),
            (draft.projectId, nil, draft.contentHash, CommandError.stalePipelineDraftCode),
            (draft.projectId, draft.baseVersionHash, "other", CommandError.pipelineHashMismatchCode)
        ] {
            XCTAssertThrowsError(try draft.checkBinding(projectId: project, currentVersionHash: version, requestedHash: hash)) {
                XCTAssertEqual(($0 as? CommandError)?.code, code)
            }
        }
        var modified = draft; modified.content += "# changed\n"
        XCTAssertThrowsError(try modified.checkBinding(projectId: draft.projectId, currentVersionHash: draft.baseVersionHash, requestedHash: draft.contentHash))
        let absent = PipelineDraft(projectId: "p", baseVersionHash: nil, content: "")
        try absent.checkBinding(projectId: "p", currentVersionHash: nil, requestedHash: absent.contentHash)
        XCTAssertThrowsError(try absent.checkBinding(projectId: "p", currentVersionHash: "new", requestedHash: absent.contentHash))
    }
    func testNewDraftRequiresExplicitNullableBaseAndKnownFieldsRemainRequired() throws {
        let draft = PipelineDraft(projectId: "p", baseVersionHash: nil, content: "")
        let data = try KabanCoding.makeEncoder().encode(draft)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["baseVersionHash"] is NSNull)
        json["future"] = true
        XCTAssertEqual(try KabanCoding.makeDecoder().decode(PipelineDraft.self, from: JSONSerialization.data(withJSONObject: json)), draft)
        for key in ["projectId", "baseVersionHash", "contentHash", "content"] {
            var missing = json; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try KabanCoding.makeDecoder().decode(PipelineDraft.self, from: JSONSerialization.data(withJSONObject: missing)), key)
            var malformed = json; malformed[key] = ["wrong": true]
            XCTAssertThrowsError(try KabanCoding.makeDecoder().decode(PipelineDraft.self, from: JSONSerialization.data(withJSONObject: malformed)), key)
        }
    }
    func testEphemeralEnvelopeHasNoDurableSeqAndToleratesFutureFields() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: KabanCoding.makeEncoder().encode(WireContractExamples.progress)) as? [String: Any])
        XCTAssertNil(json["seq"])
        json["future"] = true
        XCTAssertEqual(try KabanCoding.makeDecoder().decode(EphemeralEnvelope.self, from: JSONSerialization.data(withJSONObject: json)), WireContractExamples.progress)
        json["afterSeq"] = "not a number"
        XCTAssertThrowsError(try KabanCoding.makeDecoder().decode(EphemeralEnvelope.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}
