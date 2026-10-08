import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class ProjectSettingsTests: XCTestCase {
    func testBlockListsKeepForeignFieldsCommentsCRLFAndQuotedCommas() throws {
        let source = "# 👋\r\nworkspace:\r\n  warm_paths:\r\n    - node_modules # cache\r\n    - 'path,one'\r\n  on_create: 'echo ready'\r\nsuspicious_files: {patterns: ['*.pem'], max_file_mb: 5, allow: []}\r\nfuture: {keep: exact}\r\n"
        let doc = PipelineTextDocument(source)
        XCTAssertEqual(doc.stringList("workspace.warm_paths"), ["node_modules", "path,one"])
        let edited = try doc.replacing("workspace.warm_paths", with: "[\"cache 👋\", \"path,one\"]")
        XCTAssertEqual(edited, "# 👋\r\nworkspace:\r\n  warm_paths: [\"cache 👋\", \"path,one\"]\r\n  # cache\r\n  on_create: 'echo ready'\r\nsuspicious_files: {patterns: ['*.pem'], max_file_mb: 5, allow: []}\r\nfuture: {keep: exact}\r\n")
        XCTAssertEqual(PipelineTextDocument(edited).stringList("workspace.warm_paths"), ["cache 👋", "path,one"])
        XCTAssertEqual(try doc.replacing("suspicious_files.max_file_mb", with: "12.5"), source.replacingOccurrences(of: "max_file_mb: 5", with: "max_file_mb: 12.5"))
        XCTAssertNil(PipelineTextDocument("git: {allow: [{complex: mapping}]}\n").stringList("git.allow"))
        XCTAssertFalse(PipelineTextDocument("workspace:\n  warm_paths:\n    - nested:\n        field: data\n").canEdit("workspace.warm_paths"))
    }
    func testUnknownSourcesAndInvariantsRemainRawAndCatalogUsesExactRules() throws {
        let unknown = try JSONDecoder().decode(GitRule.self, from: Data("{\"rule\":\"future --flag\",\"source\":\"future\"}".utf8))
        XCTAssertNil(GitPolicyPresentation.label(source: unknown.source, denied: true, readOnly: true))
        XCTAssertNil(GitPolicyPresentation.invariant("new-invariant"))
        let policy = EffectiveGitPolicy(preset: .standard, allowed: [.init("restore", source: .preset), unknown],
            denied: [.init("stash", source: .stage)], hardInvariants: ["new-invariant", "push"], committer: .agentWithSafetyCommit, readOnly: true)
        XCTAssertEqual(GitPolicyPresentation.outsidePreset(catalog: ["restore", "restore --staged", "stash"], policy: policy), ["restore --staged"])
        XCTAssertEqual(GitPolicyPresentation.groups(policy.allowed).map(\.rules), [["restore"], ["future --flag"]])
        XCTAssertEqual(GitPolicyPresentation.label(source: .stage, denied: true, readOnly: true), "сужено до чтения")
        XCTAssertEqual(policy.hardInvariants, ["new-invariant", "push"])
    }
    @MainActor func testMetadataOKWaitsForCorrectProjectEventAndRetainsRefusedIdentity() async throws {
        let client = SettingsTestClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "project-settings")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let settings = ProjectSettingsStore(projectID: Fix.project, session: session)
        settings.begin(.identity); settings.editIdentity(.name, value: "Typed 👋"); settings.editIdentity(.email, value: "")
        client.failure = .init(code: "identity_required", message: IdentityDraft.generalText, params: ["missing": "email"])
        let refusedIdentity = await settings.submit(); XCTAssertFalse(refusedIdentity)
        XCTAssertEqual(settings.identity.name.value, "Typed 👋"); XCTAssertTrue(settings.identity.email.highlighted)
        settings.editIdentity(.email, value: "")
        XCTAssertTrue(settings.identity.email.highlighted); XCTAssertNotNil(settings.error)
        XCTAssertNotEqual(settings.project?.identity?.name, "Typed 👋")
        settings.begin(.resources); settings.editWeight("weight draft"); settings.begin(.identity)
        XCTAssertEqual(settings.identity.name.value, "Typed 👋")
        settings.editIdentity(.email, value: "new@example.test"); client.failure = nil
        let sentIdentity = await settings.submit(); XCTAssertTrue(sentIdentity)
        XCTAssertEqual(settings.record?.phase, .awaitingEvent); XCTAssertEqual(settings.section, .identity)
        let id = try XCTUnwrap(settings.commandID)
        client.emit(.init(seq: 11, at: Date(), projectId: "other", commandId: id, event: .projectUpdated(.init(id: "other", name: "Other", path: "/other", mascotSeed: "other"))))
        try await wait { session.projection?.stateSeq == 11 }
        XCTAssertEqual(settings.record?.phase, .awaitingEvent)
        var project = try XCTUnwrap(settings.project); project.identity = .init(name: "Typed 👋", email: "new@example.test")
        client.emit(.init(seq: 12, at: Date(), projectId: Fix.project, commandId: id, event: .projectUpdated(project)))
        try await wait { settings.record?.phase == .applied }; settings.observeOutcome()
        XCTAssertNil(settings.section); XCTAssertEqual(settings.project?.identity, project.identity)
        settings.begin(.resources); XCTAssertEqual(settings.weight, "weight draft")
    }
    @MainActor func testResourceRefusalAndDisconnectKeepInputAndDoNotInventIntegers() async throws {
        let client = SettingsTestClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "project-resources")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let settings = ProjectSettingsStore(projectID: Fix.project, session: session)
        settings.begin(.resources); settings.editWeight("not a number"); settings.editMaxRuns("3")
        let malformed = await settings.submit(); XCTAssertFalse(malformed); XCTAssertTrue(client.sent.isEmpty)
        settings.editWeight("0"); client.failure = .init(code: "invalid_request", message: "positive required")
        let refusedResources = await settings.submit(); XCTAssertFalse(refusedResources); XCTAssertEqual(settings.weight, "0"); XCTAssertEqual(settings.maxRuns, "3")
        XCTAssertNotEqual(settings.project?.weight, 0)
        settings.editWeight("5"); settings.editMaxRuns(""); client.failure = nil
        let sentResources = await settings.submit(); XCTAssertTrue(sentResources)
        XCTAssertEqual(client.sent.last?.command, .setProjectWeight(projectId: Fix.project, weight: 5, maxRuns: nil))
        session.stop(); XCTAssertEqual(settings.weight, "5"); XCTAssertEqual(settings.maxRuns, ""); XCTAssertFalse(settings.canSubmit)
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CommandError(code: "timeout", message: "Settings test timed out")
    }
}

@MainActor private final class SettingsTestClient: KabanClient {
    var failure: CommandError?
    var sent: [CommandEnvelope] = []
    var continuation: AsyncStream<EventEnvelope>.Continuation?
    func getSnapshot() async throws -> Snapshot { Fix.snapshot() }
    func synchronize() async throws -> SnapshotReplacement { .init(snapshot: try await getSnapshot(), cursor: .init(sessionId: UUID(), offset: 0), current: []) }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: ["snapshot", "command", "subscribe", "synchronize"].map { .init(name: $0, supported: true) },
              commands: CommandName.allCases.map { .init(name: $0.rawValue, support: .supported) })
    }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { continuation = $0 } }
    func emit(_ event: EventEnvelope) { continuation?.yield(event) }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        sent.append(envelope)
        return .init(commandId: envelope.commandId, seq: failure == nil ? 11 : nil, result: failure.map(CommandResult.error) ?? .ok)
    }
}
