import Foundation
import XCTest
import KabanProtocol
import KabanKit
@testable import KabanDaemonCore
@testable import KabanTransport

final class SessionContractTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_791_100_800)
    private func service(capacity: Int = 512) throws -> DaemonService {
        .init(store: try KabanStore(path: ":memory:"), liveEvents: .init(capacity: capacity))
    }
    private func progress(_ text: String) -> EphemeralEvent {
        .runProgress(.init(runId: "r", taskId: "t", message: text, lastActivityAt: at))
    }
    func testCapabilitiesEnumerateEveryCommandAndRefuseUnavailableOperations() async throws {
        let service = try service(), client = DaemonClient(transport: SessionLocalTransport(service: service))
        let capabilities = try await client.capabilities()
        XCTAssertEqual(Set(capabilities.commands.map(\.name)), Set(CommandName.allCases.map(\.rawValue)))
        XCTAssertEqual(capabilities.commands.first { $0.name == "createTask" }?.support, .managedFakeOnly)
        XCTAssertEqual(capabilities.commands.first { $0.name == "restoreWIP" }?.support, .unsupported)
        XCTAssertEqual(capabilities.commands.first { $0.name == "configureCursor" }?.support, .unsupported)
        XCTAssertEqual(capabilities.operations.first { $0.name == "readLog" }?.supported, false)
        do { _ = try await client.readLog(runId: "r", fromOffset: 0); XCTFail("Empty success hid unavailability") }
        catch { XCTAssertEqual((error as? CommandError)?.code, CommandError.unsupportedOperationCode) }
        for command in [Command.restoreWIP(taskId: "t", runId: "r", wipRef: "refs/kaban/wip/r"),
                        .configureCursor(environment: .init(executablePath: "/tool")), .getCursorEnvironment] {
            let envelope = CommandEnvelope(command: command)
            let reply = try await client.send(envelope)
            guard case .error(let error) = reply.result else { return XCTFail("Unavailable command succeeded") }
            XCTAssertEqual(error.code, CommandError.unsupportedCommandCode)
            XCTAssertEqual(error.params["command"], command.name.rawValue)
            let replay = try await client.send(envelope)
            XCTAssertEqual(replay, reply)
        }
        XCTAssertEqual(try service.store.getSnapshot().seq, 0)
    }
    func testReplacementCapturesCurrentValuesAndVolatileEventsAllocateNoSeq() async throws {
        let service = try service(), client = DaemonClient(transport: SessionLocalTransport(service: service))
        let initial = try await client.synchronize()
        _ = try service.store.execute(.init(command: .pauseAll))
        try service.publishEphemeral(progress("first"), at: at)
        try service.publishEphemeral(progress("latest"), at: at)
        let page = try await client.ephemeral(after: initial.cursor, limit: 1)
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events.first?.afterSeq, 1)
        XCTAssertEqual(page.nextCursor.offset, 1)
        XCTAssertEqual(page.latestCursor.offset, 2)
        let next = try await client.ephemeral(after: page.nextCursor, limit: 1)
        XCTAssertEqual(next.events.first?.event, progress("latest"))
        let replacement = try await client.synchronize()
        XCTAssertEqual(replacement.snapshot.seq, 1)
        XCTAssertEqual(replacement.cursor.offset, 2)
        XCTAssertEqual(replacement.current.map(\.event), [progress("latest")])
        XCTAssertEqual(try service.store.journalPage(after: 0).events.count, 1)
    }
    func testRetentionAndDaemonIncarnationRequireReplacementButKeepCurrentValues() async throws {
        let service = try service(capacity: 2), client = DaemonClient(transport: SessionLocalTransport(service: service))
        let initial = try await client.synchronize()
        try service.publishEphemeral(.runnerChecked(.init(ok: false, reason: .agentMissing, checkedAt: at)), at: at)
        for i in 0..<4 { try service.publishEphemeral(progress("\(i)"), at: at) }
        let expired = try await client.ephemeral(after: initial.cursor)
        XCTAssertTrue(expired.resetRequired); XCTAssertTrue(expired.events.isEmpty)
        let current = try await client.synchronize()
        XCTAssertEqual(current.current.count, 2, "Unchanged current values outlive the replay ring")
        XCTAssertTrue(current.current.contains { if case .runnerChecked = $0.event { return true }; return false })
        let newIncarnation = try SessionLocalTransport(service: self.service()).exchange(.init(.ephemeral(after: current.cursor, limit: 1)))
        guard case .ephemeral(let restarted) = newIncarnation.result else { return XCTFail("Missing restart response") }
        XCTAssertTrue(restarted.resetRequired)
        XCTAssertNotEqual(restarted.latestCursor.sessionId, current.cursor.sessionId)
        var future = current.cursor; future.offset += 1
        let ahead = try await client.ephemeral(after: future)
        XCTAssertTrue(ahead.resetRequired)
    }
    func testConnectionAndJournalBarrierBeforeLiveDelivery() async throws {
        let service = try service()
        let transport = BarrierTransport(service: service, event: progress("live"), at: at)
        let stream = DaemonClient(transport: transport).sessionUpdates()
        var iterator = stream.makeAsyncIterator()
        let update0 = try await iterator.next()
        XCTAssertEqual(update0, .connection(.connecting))
        let update1 = try await iterator.next()
        XCTAssertEqual(update1, .connection(.synchronizing))
        guard case .replacement(let initial) = try await iterator.next() else { return XCTFail("No replacement") }
        XCTAssertEqual(initial.snapshot.seq, 0)
        guard case .event(let durable) = try await iterator.next() else { return XCTFail("Live event bypassed journal barrier") }
        XCTAssertEqual(durable.seq, 1)
        guard case .ephemeral(let live) = try await iterator.next() else { return XCTFail("No live delivery") }
        XCTAssertEqual(live.afterSeq, durable.seq)
        XCTAssertEqual(live.cursor.offset, 1)
        let connected = try await iterator.next()
        XCTAssertEqual(connected, .connection(.connected))
    }
    func testSessionReconnectKeepsCursorAndReportsState() async throws {
        let service = try service()
        let transport = SessionReconnectTransport(service: service)
        let stream = DaemonClient(transport: transport).sessionUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next(); _ = try await iterator.next()
        guard case .replacement = try await iterator.next() else { return XCTFail("Missing initial replacement") }
        let update3 = try await iterator.next()
        XCTAssertEqual(update3, .connection(.connected))
        let update4 = try await iterator.next()
        XCTAssertEqual(update4, .connection(.reconnecting(lastSeq: 0)))
        let update5 = try await iterator.next()
        XCTAssertEqual(update5, .connection(.connected))
        let cursors = await transport.cursors
        XCTAssertEqual(cursors.count, 3); XCTAssertEqual(cursors.first, cursors.last)
    }
    func testSessionRestartReplacesStateBeforeFurtherDelivery() async throws {
        let oldService = try service(), newService = try service()
        let transport = RestartingSessionTransport(old: oldService, new: newService)
        let stream = DaemonClient(transport: transport).sessionUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next(); _ = try await iterator.next()
        guard case .replacement(let old) = try await iterator.next() else { return XCTFail("No initial state") }
        _ = try await iterator.next()
        let update6 = try await iterator.next()
        XCTAssertEqual(update6, .connection(.synchronizing))
        guard case .replacement(let new) = try await iterator.next() else { return XCTFail("No replacement after restart") }
        XCTAssertNotEqual(old.cursor.sessionId, new.cursor.sessionId)
        let update7 = try await iterator.next()
        XCTAssertEqual(update7, .connection(.connected))
    }
    func testVolatileByteBudgetRejectsOversizedPublicationWithoutAdvancingCursor() async throws {
        let service = DaemonService(store: try KabanStore(path: ":memory:"), liveEvents: .init(maxBytes: 1))
        let client = DaemonClient(transport: SessionLocalTransport(service: service))
        let before = try await client.synchronize()
        XCTAssertThrowsError(try service.publishEphemeral(progress("large"), at: at)) {
            XCTAssertEqual($0 as? DaemonTransportError, .payloadTooLarge)
        }
        let after = try await client.synchronize()
        XCTAssertEqual(after, before)
        let bounded = DaemonService(store: try KabanStore(path: ":memory:"), liveEvents: .init(maxBytes: 2048))
        let boundedClient = DaemonClient(transport: SessionLocalTransport(service: bounded))
        let initial = try await boundedClient.synchronize()
        for _ in 0..<5 { try bounded.publishEphemeral(progress(String(repeating: "x", count: 700)), at: at) }
        let expired = try await boundedClient.ephemeral(after: initial.cursor)
        XCTAssertTrue(expired.resetRequired, "Byte retention applies before the event-count limit")
    }
    func testOlderLiveFlagsCannotOverwriteDurableResumeOrReplacement() async throws {
        let service = try service()
        _ = try service.store.execute(.init(command: .pauseAll))
        try service.publishEphemeral(.schedulerFlagsChanged([.macPaused]), at: at)
        _ = try service.store.execute(.init(command: .resumeAll))
        let replacement = try await DaemonClient(transport: SessionLocalTransport(service: service)).synchronize()
        XCTAssertTrue(replacement.snapshot.schedulerFlags.isEmpty)
        XCTAssertTrue(replacement.current.isEmpty, "Replacement cannot reapply superseded live flags")

        let liveService = try self.service()
        let stream = DaemonClient(transport: StaleFlagsTransport(service: liveService, at: at)).sessionUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next(); _ = try await iterator.next(); _ = try await iterator.next()
        guard case .event(let pause) = try await iterator.next() else { return XCTFail("Missing pause") }
        guard case .event(let resume) = try await iterator.next() else { return XCTFail("Missing resume") }
        XCTAssertEqual(pause.seq, 1); XCTAssertEqual(resume.seq, 2)
        let next = try await iterator.next()
        XCTAssertEqual(next, .connection(.connected), "Superseded live flag should be coalesced")
    }
    func testMalformedNewRepliesAreRejectedAndLogTailUsesExactOffsets() async throws {
        let cursor = EphemeralCursor(sessionId: UUID(), offset: 0)
        let wrong = EphemeralEnvelope(cursor: .init(sessionId: cursor.sessionId, offset: 2), afterSeq: 0, at: at, event: progress("x"))
        let client = DaemonClient(transport: ConstantTransport(response: .init(.ephemeral(.init(fromCursor: cursor,
            nextCursor: wrong.cursor, latestCursor: wrong.cursor, events: [wrong])))))
        do { _ = try await client.ephemeral(after: cursor); XCTFail("Gap accepted") }
        catch { XCTAssertEqual(error as? DaemonTransportError, .invalidReply) }
        let bad = LogPage(batch: .init(runId: "other", fromOffset: 0, nextOffset: 1, events: [.result(ok: true, durationMs: nil)]),
                          availableFromOffset: 0, endOffset: 1, isComplete: true)
        do { _ = try await DaemonClient(transport: ConstantTransport(response: .init(.log(bad)))).readLog(runId: "r", fromOffset: 0); XCTFail("Wrong run accepted") }
        catch { XCTAssertEqual(error as? DaemonTransportError, .invalidReply) }
        let transport = LogPagesTransport()
        var batches: [LogBatch] = []
        for try await batch in DaemonClient(transport: transport).tailLog(runId: "r", fromOffset: 4) { batches.append(batch) }
        XCTAssertEqual(batches.map(\.fromOffset), [4, 5])
        XCTAssertEqual(batches.map(\.nextOffset), [5, 6])
        let offsets = await transport.offsets
        XCTAssertEqual(offsets, [4, 5])
    }
    func testDraftValidationAndMismatchedApplyNeverChangeProjection() async throws {
        let store = try makeDaemonTransportFixture(on: self)
        let version = try XCTUnwrap(store.getSnapshot().pipelines.first?.versionHash)
        let before = try store.getSnapshot()
        let content = """
        version: 1
        stages:
          - {id: queue, kind: queue, on_success: agent}
          - id: agent
            kind: agent
            agent: {model: explicit, skill: dev.md}
            on_success: review
          - {id: review, kind: human, on_success: merge}
          - {id: merge, kind: merge, wip: 1, on_success: done}
          - {id: done, kind: terminal}
        """
        let draft = PipelineDraft(projectId: "p", baseVersionHash: version, content: content)
        let client = DaemonClient(transport: SessionLocalTransport(service: .init(store: store)))
        let reply = try await client.send(.init(command: .validatePipelineDraft(draft: draft)))
        guard case .pipelineDraft(let validation) = reply.result else { return XCTFail("No validation") }
        XCTAssertEqual(validation.contentHash, draft.contentHash); XCTAssertEqual(validation.baseVersionHash, version)
        XCTAssertFalse(validation.issues.contains { $0.severity == .error }, "\(validation.issues)")
        XCTAssertNil(reply.seq)
        var stale = draft; stale.baseVersionHash = "other"
        var other = draft; other.projectId = "other"
        var changed = draft; changed.content += "# race"
        for (candidate, code) in [(stale, CommandError.stalePipelineDraftCode), (other, CommandError.stalePipelineDraftCode),
                                  (changed, CommandError.pipelineHashMismatchCode), (draft, CommandError.unsupportedCommandCode)] {
            let envelope = CommandEnvelope(command: .updatePipeline(projectId: "p", contentHash: draft.contentHash, draft: candidate))
            let result = try await client.send(envelope)
            guard case .error(let error) = result.result else { return XCTFail("Applied unsupported/stale draft") }
            XCTAssertEqual(error.code, code)
            let replay = try await client.send(envelope); XCTAssertEqual(replay, result)
        }
        XCTAssertEqual(try store.getSnapshot(), before)
        let legacy = try await client.send(.init(command: .updatePipeline(projectId: "p", contentHash: draft.contentHash)))
        guard case .error(let error) = legacy.result else { return XCTFail("Hash-only update succeeded") }
        XCTAssertEqual(error.code, "pipeline_draft_required")
        // Fixed fake fixture MUST retain production merge_count in live validation.
        let fakeText = content.replacingOccurrences(of: "on_success: merge", with: "on_success: done")
            .replacingOccurrences(of: "  - {id: merge, kind: merge, wip: 1, on_success: done}\n", with: "")
        let invalid = try await client.send(.init(command: .validatePipeline(projectId: "p", content: fakeText)))
        guard case .validationIssues(let issues) = invalid.result else { return XCTFail("Invalid fake pipeline approved") }
        XCTAssertTrue(issues.contains { $0.code == "merge_count" })
    }
}

private struct SessionLocalTransport: DaemonTransport {
    let service: DaemonService
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        try DaemonWire.decode(DaemonResponse.self, from: service.handle(data: DaemonWire.encode(request)))
    }
}
private struct ConstantTransport: DaemonTransport {
    let response: DaemonResponse
    func exchange(_ request: DaemonRequest) -> DaemonResponse { response }
}
private actor BarrierTransport: DaemonTransport {
    let service: DaemonService, event: EphemeralEvent, at: Date
    var injected = false
    init(service: DaemonService, event: EphemeralEvent, at: Date) { self.service = service; self.event = event; self.at = at }
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        if case .ephemeral = request.operation, !injected {
            injected = true
            _ = try service.store.execute(.init(command: .pauseAll))
            try service.publishEphemeral(event, at: at)
        }
        return service.handle(request)
    }
}
private actor SessionReconnectTransport: DaemonTransport {
    let service: DaemonService
    var cursors: [EphemeralCursor] = []
    init(service: DaemonService) { self.service = service }
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        if case .ephemeral(let cursor, _) = request.operation {
            cursors.append(cursor)
            if cursors.count == 2 { throw DaemonTransportError.connectionLost }
        }
        return service.handle(request)
    }
}
private actor RestartingSessionTransport: DaemonTransport {
    let old: DaemonService, new: DaemonService
    var restarted = false
    var polls = 0
    init(old: DaemonService, new: DaemonService) { self.old = old; self.new = new }
    func exchange(_ request: DaemonRequest) -> DaemonResponse {
        if case .ephemeral = request.operation { polls += 1; restarted = polls >= 2 }
        return (restarted ? new : old).handle(request)
    }
}
private actor LogPagesTransport: DaemonTransport {
    var offsets: [Int64] = []
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        guard case .readLog(let run, let offset, _) = request.operation else { throw DaemonTransportError.invalidReply }
        offsets.append(offset)
        return .init(.log(.init(batch: .init(runId: run, fromOffset: offset, nextOffset: offset + 1,
                                            events: [.message(role: "assistant", text: "\(offset)")]),
                               availableFromOffset: 4, endOffset: 6, isComplete: true)))
    }
}
private actor StaleFlagsTransport: DaemonTransport {
    let service: DaemonService, at: Date
    var injected = false
    init(service: DaemonService, at: Date) { self.service = service; self.at = at }
    func exchange(_ request: DaemonRequest) throws -> DaemonResponse {
        if case .ephemeral = request.operation, !injected {
            injected = true
            _ = try service.store.execute(.init(command: .pauseAll))
            try service.publishEphemeral(.schedulerFlagsChanged([.macPaused]), at: at)
            _ = try service.store.execute(.init(command: .resumeAll))
        }
        return service.handle(request)
    }
}
