import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

@MainActor final class IncidentDecisionTests: XCTestCase {
    private func incident(kind: IncidentKind = .refsMoved) -> Incident {
        .init(id: "incident", projectId: Fix.project, taskId: "t", runId: "run", kind: kind, rolledBack: ["refs/heads/forbidden"], openedAt: Fix.t0)
    }
    private func detail(stage: String = "dev") -> TaskDetail {
        var pipeline = Fix.pipeline(); pipeline.defaultReturnStage = "dev"
        pipeline.stages[1].onSuccess = "gate"
        return .init(seq: 10, task: Fix.card("t", stage: stage, state: .waitingHuman(.incident)), feed: [], runs: [], incidentPipeline: pipeline)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CommandError(code: "test_timeout", message: "Incident decision timeout")
    }
    func testFrozenTargetsIncludeCurrentWritableAgentAndRequireExactIncident() throws {
        let context = try XCTUnwrap(IncidentDecisionContext(incident: incident(), detail: detail()))
        XCTAssertEqual(context.targets.map(\.id), ["dev"])
        let text = "Проверь refs  \r\n👋"
        XCTAssertEqual(context.command(current: context, target: "dev", comments: text), .requestChanges(taskId: "t", comments: text, target: "dev"))
        XCTAssertNil(context.command(current: context, target: "test", comments: text))
        XCTAssertNil(context.command(current: context, target: "dev", comments: " \n"))
        var newer = incident(); newer.rolledBack.append("refs/tags/forbidden")
        XCTAssertNil(context.command(current: .init(incident: newer, detail: detail()), target: "dev", comments: text))
        XCTAssertNil(IncidentDecisionContext(incident: incident(kind: .init(rawValue: "future")), detail: detail()))
        var legacy = detail(); legacy.incidentPipeline = nil
        XCTAssertNil(IncidentDecisionContext(incident: incident(), detail: legacy))
        var unrelated = incident(); unrelated.taskId = "other"
        XCTAssertNil(IncidentDecisionContext(incident: unrelated, detail: detail()))
        var resolved = incident(); resolved.resolvedAt = Fix.t0
        XCTAssertNil(IncidentDecisionContext(incident: resolved, detail: detail()))
        XCTAssertEqual(IncidentDecisionContext(incident: incident(), detail: detail(stage: "gate"))?.targets.map(\.id), ["dev"])
    }
    func testOKDoesNotResolveAndCorrelatedEventsConfirmCardCountAndDurableHistory() async throws {
        let client = IncidentDecisionClient(detail: detail(), incident: incident()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "session")
        let loop = Task { await session.run() }; defer { loop.cancel(); session.stop() }
        try await wait { session.canSend }; await session.select("t")
        let reader = IncidentsStore(client: client, session: session); await reader.refresh()
        let decisions = IncidentDecisionStore(session: session, incidents: reader, storage: storage, key: "decisions")
        let text = "Сохранить  \r\n👋"
        decisions.edit("incident", comments: text)
        XCTAssertTrue(decisions.canSubmit("incident"))
        let sent = await decisions.submit("incident"); XCTAssertTrue(sent)
        try await wait { session.canSend }
        XCTAssertEqual(decisions.receipt("incident")?.phase, .awaitingEvent)
        XCTAssertEqual(reader.records.first?.resolvedAt, nil)
        XCTAssertEqual(session.projection?.openIncidentCount, 1)
        XCTAssertEqual(session.projection?.tasks["t"]?.state, .waitingHuman(.incident))
        let again = await decisions.submit("incident"); XCTAssertFalse(again)
        XCTAssertEqual(Set(client.sent.map(\.commandId)).count, 1)
        let reopened = IncidentDecisionStore(session: session, incidents: reader, storage: storage, key: "decisions")
        XCTAssertEqual(reopened.draft("incident")?.comments, text)
        XCTAssertFalse(reopened.canSubmit("incident"))
        let command = try XCTUnwrap(client.sent.first)
        let resolution = IncidentResolution(command: "requestChanges", target: "dev", commandId: command.commandId)
        var resolved = incident(); resolved.resolvedAt = Fix.t0; resolved.resolution = resolution; client.record = resolved
        try session.consume(.event(Fix.envelope(11, .incidentResolved(.init(incidentId: "incident", by: .human, commandId: command.commandId, resolution: resolution)), commandId: command.commandId)))
        XCTAssertEqual(decisions.receipt("incident")?.phase, .awaitingEvent)
        var project = Fix.project(); project.openIncidentCount = 0
        try session.consume(.event(Fix.envelope(12, .projectUpdated(project), commandId: command.commandId)))
        var card = detail().task; card.state = .queued(nil)
        client.detail.task = card; client.detail.seq = 13
        try session.consume(.event(Fix.envelope(13, .taskUpdated(card), commandId: command.commandId)))
        XCTAssertEqual(decisions.receipt("incident")?.phase, .applied)
        XCTAssertEqual(session.projection?.openIncidentCount, 0)
        await reader.refresh(); reader.filter = .all
        XCTAssertEqual(reader.visible.first?.resolution, resolution)
        reader.filter = .open; XCTAssertTrue(reader.visible.isEmpty)
    }
    func testStaleDraftKeepsCommentAndNeedsExplicitRetarget() async throws {
        let client = IncidentDecisionClient(detail: detail(), incident: incident()), storage = MemoryKeyValueStore()
        let session = BoardSession(client: client, storage: storage, key: "stale")
        let loop = Task { await session.run() }; defer { loop.cancel(); session.stop() }
        try await wait { session.canSend }; await session.select("t")
        let reader = IncidentsStore(client: client, session: session); await reader.refresh()
        let decisions = IncidentDecisionStore(session: session, incidents: reader, storage: storage, key: "draft")
        decisions.edit("incident", comments: "Exact 👋")
        client.record.rolledBack.append("another-ref"); await reader.refresh()
        XCTAssertFalse(decisions.canSubmit("incident"))
        XCTAssertEqual(decisions.draft("incident")?.comments, "Exact 👋")
        decisions.useCurrent("incident"); XCTAssertTrue(decisions.canSubmit("incident"))
    }
    func testMockResolutionUsesSameDTOAndHistoryQuery() async throws {
        let value = detail(), opened = incident()
        let client = MockKabanClient(snapshot: Fix.snapshot(tasks: [value.task], projects: [Fix.project(openIncidentCount: 1)], pipelines: [try XCTUnwrap(value.incidentPipeline)], openIncidents: 1), incidents: [opened])
        let command = CommandEnvelope(command: .requestChanges(taskId: "t", comments: "Check refs", target: "dev"))
        let reply = try await client.send(command); XCTAssertEqual(reply.result, .ok)
        let snapshot = try await client.getSnapshot()
        XCTAssertEqual(snapshot.openIncidentCount, 0)
        guard case .incidents(let history) = try await client.send(.init(command: .listIncidents(projectIds: nil, state: .all))).result else { return XCTFail() }
        XCTAssertEqual(history.first?.resolution, .init(command: "requestChanges", target: "dev", commandId: command.commandId))
        XCTAssertNotNil(history.first?.resolvedAt)
    }
}

@MainActor private final class IncidentDecisionClient: KabanClient {
    let base: MockKabanClient
    var detail: TaskDetail
    var record: Incident
    var sent: [CommandEnvelope] = []
    init(detail: TaskDetail, incident: Incident) {
        self.detail = detail; record = incident
        base = MockKabanClient(snapshot: Fix.snapshot(tasks: [detail.task], projects: [Fix.project(openIncidentCount: 1)], pipelines: [detail.incidentPipeline!], openIncidents: 1))
    }
    func getSnapshot() async throws -> Snapshot { try await base.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await base.synchronize() }
    func capabilities() async throws -> DaemonCapabilities { try await base.capabilities() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { base.updates() }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        switch envelope.command {
        case .getTaskDetail: return .init(commandId: envelope.commandId, seq: nil, result: .taskDetail(detail))
        case .listIncidents: return .init(commandId: envelope.commandId, seq: nil, result: .incidents([record]))
        case .requestChanges: sent.append(envelope); return .init(commandId: envelope.commandId, seq: nil, result: .ok)
        default: return try await base.send(envelope)
        }
    }
}
