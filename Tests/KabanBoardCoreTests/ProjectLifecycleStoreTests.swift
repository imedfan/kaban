import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class ProjectLifecycleStoreTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(3)
        while !condition() { if Date() > limit { XCTFail("Timed out"); throw CancellationError() }; try await Task.sleep(for: .milliseconds(5)) }
    }
    @MainActor func testIdentityRefusalsPreserveFolderAndTemplateAndUseOnlyDaemonParams() async throws {
        let client = ProjectClient(), storage = MemoryKeyValueStore(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "commands")
        let run = Task { await session.run() }; defer { run.cancel() }; try await wait { session.canSend }
        let model = ProjectLifecycleStore(client: client, session: session, storage: storage, key: "drafts")
        model.open(.add); model.editPath("/chosen/repository"); model.setCreateTemplate(false)
        client.result = .error(.init(code: "identity_required", message: IdentityDraft.generalText, params: ["missing": "email", "name": "Repo Author"]))
        let first = await model.submit(); XCTAssertFalse(first)
        XCTAssertEqual(client.mutations.last?.command, .addProject(path: "/chosen/repository", createTemplate: false, identity: nil))
        XCTAssertTrue(model.draft.showsIdentity); XCTAssertEqual(model.draft.identity.name.value, "Repo Author")
        XCTAssertTrue(model.draft.identity.name.fromGitSettings); XCTAssertFalse(model.draft.identity.email.highlighted)
        XCTAssertEqual(model.draft.identity.focus, .email); XCTAssertEqual(session.projection?.projects.count, 0)
        model.editIdentity(.name, value: " My Author "); model.editIdentity(.email, value: " ")
        model.open(.add); XCTAssertEqual(model.draft.identity.name.value, " My Author "); XCTAssertEqual(model.draft.identity.email.value, " ")
        client.result = .error(.init(code: "identity_required", message: IdentityDraft.generalText, params: ["missing": "email"]))
        let second = await model.submit(); XCTAssertFalse(second)
        XCTAssertEqual(client.mutations.last?.command, .addProject(path: "/chosen/repository", createTemplate: false, identity: .init(name: " My Author ", email: " ")))
        XCTAssertTrue(model.draft.identity.email.highlighted); XCTAssertEqual(model.draft.identity.email.caption, "Укажите почту")
        let reopened = ProjectLifecycleStore(client: client, session: session, storage: storage, key: "drafts")
        reopened.open(.add); XCTAssertEqual(reopened.draft.path, "/chosen/repository"); XCTAssertFalse(reopened.draft.createTemplate)
        XCTAssertEqual(reopened.draft.identity.name.value, " My Author "); XCTAssertEqual(reopened.draft.identity.email.value, " ")
        XCTAssertEqual(Set(client.mutations.map(\.commandId)).count, 2, "A known refusal permits one new corrected intent")
    }
    @MainActor func testAcknowledgementCannotAddProjectAndPendingReopensWithExactEnvelope() async throws {
        let client = ProjectClient(), storage = MemoryKeyValueStore(), session = BoardSession(client: client, storage: storage, key: "commands")
        let run = Task { await session.run() }; defer { run.cancel() }; try await wait { session.canSend }
        let model = ProjectLifecycleStore(client: client, session: session, storage: storage, key: "drafts")
        model.open(.add); model.editPath("/chosen/repository"); model.setCreateTemplate(false)
        let sent = await model.submit(); XCTAssertTrue(sent); try await wait { session.canSend }
        XCTAssertEqual(model.phase, .awaitingEvent); XCTAssertFalse(model.canSubmit); XCTAssertNil(model.connectedProjectID)
        XCTAssertEqual(session.projection?.projects.count, 0)
        let original = try XCTUnwrap(client.mutations.first)
        let reopened = ProjectLifecycleStore(client: client, session: session, storage: storage, key: "drafts")
        reopened.open(.add); reopened.editPath("/other"); let duplicate = await reopened.submit(); XCTAssertFalse(duplicate)
        XCTAssertEqual(reopened.draft.path, "/chosen/repository"); XCTAssertEqual(reopened.draft.commandID, original.commandId)
        XCTAssertTrue(client.mutations.allSatisfy { $0 == original })
        let project = ProjectSummary(id: "new", name: "repository", path: "/daemon/canonical/alias", mascotSeed: "new")
        try session.consume(.event(.init(seq: 1, at: Date(), projectId: project.id, commandId: original.commandId, event: .projectAdded(project))))
        reopened.observeOutcome(); XCTAssertEqual(reopened.connectedProjectID, project.id)
        XCTAssertEqual(session.visibleIDs, [project.id]); XCTAssertEqual(reopened.phase, .applied)
        XCTAssertEqual(try ClientCommandJournal(storage: storage, key: "commands").records.first?.createdProjectID, project.id)
    }
    @MainActor func testProjectEventBeforeLostReplyStillCompletesExactlyOneIntent() async throws {
        let client = ProjectClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "commands")
        let run = Task { await session.run() }; defer { run.cancel() }; try await wait { session.canSend }
        let model = ProjectLifecycleStore(client: client, session: session, storage: MemoryKeyValueStore(), key: "drafts")
        model.open(.add); model.editPath("/chosen/repository")
        var held: CheckedContinuation<CommandReply, Error>?
        client.mutationHandler = { _ in try await withCheckedThrowingContinuation { held = $0 } }
        let submission = Task { await model.submit() }; try await wait { held != nil }
        let envelope = try XCTUnwrap(client.mutations.first), project = Fix.project()
        try session.consume(.event(.init(seq: 1, at: Date(), projectId: project.id, commandId: envelope.commandId, event: .projectAdded(project))))
        model.observeOutcome(); XCTAssertEqual(model.phase, .applied); XCTAssertEqual(model.connectedProjectID, project.id)
        held?.resume(throwing: CommandError(code: "lost_reply", message: "Lost reply after commit"))
        let result = await submission.value; XCTAssertTrue(result)
        XCTAssertEqual(client.mutations.count, 1); XCTAssertEqual(session.projection?.projectOrder, [project.id]); XCTAssertFalse(model.canSubmit)
    }
    @MainActor func testNonGitAndLegacyIdentityFailureLeaveNoLaneOrInventedHighlights() async throws {
        let client = ProjectClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "commands")
        let run = Task { await session.run() }; defer { run.cancel() }; try await wait { session.canSend }
        let model = ProjectLifecycleStore(client: client, session: session, storage: MemoryKeyValueStore(), key: "drafts")
        model.open(.add); model.editPath("/not-git")
        client.result = .error(.init(code: "not_git_repository", message: "Не git-репозиторий")); _ = await model.submit()
        XCTAssertEqual(model.draft.path, "/not-git"); XCTAssertEqual(session.visibleIDs, []); XCTAssertFalse(model.draft.showsIdentity)
        client.result = .error(.init(code: "identity_required", message: IdentityDraft.generalText)); _ = await model.submit()
        XCTAssertTrue(model.draft.showsIdentity); XCTAssertFalse(model.draft.identity.name.highlighted); XCTAssertFalse(model.draft.identity.email.highlighted)
        XCTAssertNil(model.draft.identity.focus); XCTAssertEqual(session.visibleIDs, [])
    }
    @MainActor func testRelinkAndRemoveAwaitTheirOwnEventsAndKeepTaskIdentity() async throws {
        let client = ProjectClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "commands")
        var project = Fix.project(); client.snapshot = Fix.snapshot(seq: 0, tasks: [Fix.card("task")])
        let run = Task { await session.run() }; defer { run.cancel() }; try await wait { session.canSend }
        let model = ProjectLifecycleStore(client: client, session: session, storage: MemoryKeyValueStore(), key: "drafts")
        model.open(.relink(project.id)); model.editPath("/relocated"); _ = await model.submit(); try await wait { session.canSend }
        XCTAssertEqual(session.projection?.projects[project.id]?.path, project.path)
        let relink = try XCTUnwrap(model.draft.commandID); project.path = "/relocated"
        try session.consume(.event(.init(seq: 1, at: Date(), projectId: project.id, commandId: relink, event: .projectUpdated(project))))
        model.observeOutcome(); XCTAssertEqual(model.phase, .applied); XCTAssertEqual(session.projection?.projects[project.id]?.path, "/relocated"); XCTAssertEqual(session.projection?.tasks["task"]?.projectId, project.id)
        client.snapshot = Snapshot(seq: 1, projects: [project], pipelines: [Fix.pipeline()], tasks: [Fix.card("task")])
        model.open(.remove(project.id)); _ = await model.submit(); try await wait { session.canSend }
        XCTAssertNotNil(session.projection?.projects[project.id]); let removal = try XCTUnwrap(model.draft.commandID)
        try session.consume(.event(.init(seq: 2, at: Date(), projectId: project.id, commandId: removal, event: .projectRemoved(project.id))))
        model.observeOutcome(); XCTAssertEqual(model.phase, .applied); XCTAssertNil(session.projection?.projects[project.id]); XCTAssertEqual(session.visibleIDs, [])
    }
    @MainActor func testDiagnosticsUseCorrelatedRepliesAndDiscardPreviousFormRead() async throws {
        let client = ProjectClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "commands")
        client.snapshot = Fix.snapshot()
        let run = Task { await session.run() }; defer { run.cancel() }; try await wait { session.canSend }
        let model = ProjectLifecycleStore(client: client, session: session, storage: MemoryKeyValueStore(), key: "drafts")
        model.open(.relink(Fix.project)); await model.refreshDiagnostics()
        XCTAssertEqual(model.branches, ["main", "feature"]); XCTAssertEqual(model.gates, ["swift build"]); XCTAssertNil(model.environment)
        XCTAssertNotNil(model.environmentError, "Unsupported environment stays unknown")
        client.badCorrelation = true; await model.refreshDiagnostics(); XCTAssertTrue(model.diagnosticsStale); XCTAssertNotNil(model.branchesError)
        client.badCorrelation = false; client.holdBranches = true
        let reading = Task { await model.refreshDiagnostics() }; try await wait { client.held != nil }
        model.open(.add); client.held?.resume(returning: .init(commandId: client.heldID!, seq: nil, result: .branches(["stale"]))); await reading.value
        XCTAssertNil(model.branches); XCTAssertNil(model.gates); XCTAssertNil(model.environment)
    }
}

@MainActor private final class ProjectClient: KabanClient {
    var snapshot = Snapshot(seq: 0, projects: [], pipelines: [], tasks: [])
    let cursor = EphemeralCursor(sessionId: UUID(), offset: 0)
    var result = CommandResult.ok
    var mutations: [CommandEnvelope] = []
    var mutationHandler: ((CommandEnvelope) async throws -> CommandReply)?
    var badCorrelation = false, holdBranches = false
    var held: CheckedContinuation<CommandReply, Error>?
    var heldID: CommandID?
    func getSnapshot() async throws -> Snapshot { snapshot }
    func synchronize() async throws -> SnapshotReplacement { .init(snapshot: snapshot, cursor: cursor, current: []) }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: [.init(name: "synchronize", supported: true)], commands: [CommandName.addProject, .removeProject, .relinkProject, .listBranches, .detectGates].map { .init(name: $0.rawValue, support: .supported) })
    }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { AsyncThrowingStream { $0.yield(.connection(.connected)) } }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { $0.finish() } }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        let value: CommandResult
        switch envelope.command {
        case .listBranches:
            if holdBranches { heldID = envelope.commandId; return try await withCheckedThrowingContinuation { held = $0 } }
            value = .branches(["main", "feature"])
        case .detectGates: value = .gates(["swift build"])
        default:
            mutations.append(envelope)
            if let mutationHandler { return try await mutationHandler(envelope) }
            value = result
        }
        return .init(commandId: badCorrelation ? CommandID() : envelope.commandId, seq: envelope.command.mutationScope == nil ? nil : 0, result: value)
    }
}
