import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class RunnerEnvironmentStoreTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor func testUnsupportedEnvironmentRemainsUnknownAndDoesNotProbe() async throws {
        let client = EnvironmentClient(); client.supported = []
        let session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        let runner = RunnerEnvironmentStore(client: client, session: session)
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }; await runner.refresh()
        runner.editPath("/chosen/path")
        XCTAssertNil(runner.report); XCTAssertNil(runner.configuration)
        XCTAssertNotNil(runner.reportError); XCTAssertNotNil(runner.configurationError)
        XCTAssertFalse(runner.canConfigure); XCTAssertEqual(client.reads, [])
        XCTAssertTrue(session.canSend, "Unavailable runner must not block Backlog")
    }
    @MainActor func testDiscoveryIsKnownAndRefreshPreservesEditedPath() async throws {
        let client = EnvironmentClient()
        let actual = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        let runner = RunnerEnvironmentStore(client: client, session: actual)
        let task = Task { await actual.run() }; defer { task.cancel() }
        try await wait { actual.canSend }; await runner.refresh()
        XCTAssertEqual(runner.configuration, .init(executablePath: nil)); XCTAssertEqual(runner.draftPath, "")
        runner.editPath("/my/cursor-agent")
        client.configuration = .init(executablePath: "/external/path")
        await runner.refresh()
        XCTAssertEqual(runner.draftPath, "/my/cursor-agent"); XCTAssertTrue(runner.canConfigure)
        XCTAssertEqual(runner.configuration?.executablePath, "/external/path")
    }
    @MainActor func testLateEnvironmentReplyAfterReconnectCannotLookFresh() async throws {
        let client = EnvironmentClient()
        let actual = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        let runner = RunnerEnvironmentStore(client: client, session: actual)
        let task = Task { await actual.run() }; defer { task.cancel() }
        try await wait { actual.canSend }; await runner.refresh()
        let original = runner.report
        client.holdReport = true
        let read = Task { await runner.refresh() }
        try await wait { client.heldReport != nil }
        try actual.consume(.connection(.reconnecting(lastSeq: 0)))
        try actual.consume(.connection(.connected)); try await wait { actual.canSend }
        client.completeReport(.init(cursorAgentPath: "/stale", version: "stale", authOK: true, gitVersion: "stale", sandboxOK: true, notificationsAuthorized: true))
        await read.value
        XCTAssertEqual(runner.report, original); XCTAssertTrue(runner.isStale)
        client.holdReport = false; await runner.refresh(); XCTAssertFalse(runner.isStale)
    }
    @MainActor func testAcknowledgementDoesNotClaimPathSavedOrPermitSecondSubmission() async throws {
        let client = EnvironmentClient()
        let actual = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        let runner = RunnerEnvironmentStore(client: client, session: actual)
        let task = Task { await actual.run() }; defer { task.cancel() }
        try await wait { actual.canSend }; await runner.refresh(); runner.editPath("/chosen/cursor")
        let accepted = await runner.savePath(); XCTAssertTrue(accepted)
        try await wait { actual.canSend }
        XCTAssertEqual(runner.submissionPhase, .awaitingEvent); XCTAssertFalse(runner.canConfigure)
        let second = await runner.savePath(); XCTAssertFalse(second)
        XCTAssertEqual(Set(client.mutations.map(\.commandId)).count, 1, "Reconciliation must retain the exact ID")
        guard let command = runner.submittedCommandID else { return XCTFail("No pending command") }
        client.configuration = .init(executablePath: "/chosen/cursor"); client.snapshot.seq = 1
        try actual.consume(.event(.init(seq: 1, at: Date(), projectId: nil, commandId: command, event: .cursorEnvironmentChanged(client.configuration))))
        await runner.refresh()
        XCTAssertEqual(runner.submissionPhase, .applied); XCTAssertFalse(runner.isEdited)
        XCTAssertEqual(runner.configuration?.executablePath, "/chosen/cursor")
    }
    @MainActor func testReopenedUnknownConfigurationKeepsTheSubmittedPathAndExactEnvelope() async throws {
        let storage = MemoryKeyValueStore(), client = EnvironmentClient()
        let envelope = CommandEnvelope(command: .configureCursor(environment: .init(executablePath: "/chosen/before-restart")))
        let journal = try ClientCommandJournal(storage: storage, key: "test")
        try journal.begin(envelope); try journal.markUncertain(envelope.commandId)
        let session = BoardSession(client: client, storage: storage, key: "test")
        let runner = RunnerEnvironmentStore(client: client, session: session)
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }; await runner.refresh()
        XCTAssertEqual(runner.submittedCommandID, envelope.commandId)
        XCTAssertEqual(runner.draftPath, "/chosen/before-restart")
        XCTAssertEqual(runner.configuration, .init(executablePath: nil), "A cached acknowledgement did not persist the chosen path")
        XCTAssertEqual(runner.submissionPhase, .awaitingEvent); XCTAssertFalse(runner.canConfigure)
        XCTAssertFalse(client.mutations.isEmpty); XCTAssertTrue(client.mutations.allSatisfy { $0 == envelope })
    }
    @MainActor func testRunnerRecheckRequiresTheDeclaredRunnerScope() async throws {
        let client = EnvironmentClient(); client.recheckScopes = ["project"]
        let session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        let runner = RunnerEnvironmentStore(client: client, session: session)
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }
        XCTAssertFalse(runner.canRecheck)
        let sent = await runner.recheck(); XCTAssertFalse(sent); XCTAssertEqual(client.mutations, [])
        XCTAssertNil(runner.report)
        client.recheckScopes = ["runner"]
        try session.consume(.capabilities(try await client.capabilities()))
        XCTAssertTrue(runner.canRecheck)
    }
    @MainActor func testMalformedCorrelationAndReadFailureKeepDraftAndLastKnownReport() async throws {
        let client = EnvironmentClient()
        let session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "test")
        let runner = RunnerEnvironmentStore(client: client, session: session)
        let task = Task { await session.run() }; defer { task.cancel() }
        try await wait { session.canSend }; await runner.refresh(); let original = runner.report
        runner.editPath("/unsent"); client.badCorrelation = true; await runner.refresh()
        XCTAssertEqual(runner.report, original); XCTAssertTrue(runner.isStale)
        XCTAssertEqual(runner.draftPath, "/unsent"); XCTAssertFalse(runner.canConfigure)
        XCTAssertTrue(runner.reportError?.contains("некорректный") == true)
    }
}

@MainActor private final class EnvironmentClient: KabanClient {
    var snapshot = Snapshot(seq: 0, projects: [], pipelines: [], tasks: [])
    let cursor = EphemeralCursor(sessionId: UUID(), offset: 0)
    var configuration = CursorEnvironment(executablePath: nil)
    var report = EnvironmentReport(cursorAgentPath: nil, version: nil, authOK: false, gitVersion: "git 2", sandboxOK: true, notificationsAuthorized: false)
    var supported: Set<CommandName> = [.getCursorEnvironment, .checkEnvironment, .configureCursor, .recheck]
    var recheckScopes: [String]? = ["runner"]
    var reads: [CommandName] = []
    var mutations: [CommandEnvelope] = []
    var badCorrelation = false
    var holdReport = false
    var heldReport: (CommandEnvelope, CheckedContinuation<CommandReply, Error>)?
    func getSnapshot() async throws -> Snapshot { snapshot }
    func synchronize() async throws -> SnapshotReplacement { .init(snapshot: snapshot, cursor: cursor, current: []) }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: [.init(name: "synchronize", supported: true)], commands: supported.map { .init(name: $0.rawValue, support: .supported, scopes: $0 == .recheck ? recheckScopes : nil) })
    }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { AsyncThrowingStream { $0.yield(.connection(.connected)) } }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { $0.finish() } }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if case .checkEnvironment = envelope.command, holdReport {
            return try await withCheckedThrowingContinuation { heldReport = (envelope, $0) }
        }
        let result: CommandResult
        switch envelope.command {
        case .getCursorEnvironment: reads.append(envelope.command.name); result = .cursorEnvironment(configuration)
        case .checkEnvironment: reads.append(envelope.command.name); result = .environment(report)
        default: mutations.append(envelope); result = .ok
        }
        return .init(commandId: badCorrelation ? CommandID() : envelope.commandId, seq: envelope.command.mutationScope == nil ? nil : 0, result: result)
    }
    func completeReport(_ value: EnvironmentReport) {
        guard let heldReport else { return }; self.heldReport = nil
        heldReport.1.resume(returning: .init(commandId: heldReport.0.commandId, seq: nil, result: .environment(value)))
    }
}
