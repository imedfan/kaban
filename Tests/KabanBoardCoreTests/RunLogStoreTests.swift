import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class RunLogStoreTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Log store did not reach expected state")
        throw CommandError(code: "test_timeout", message: "Log timeout")
    }
    @MainActor func testReconnectContinuesConsumedCursorAndDeduplicatesOverlap() async throws {
        let client = LogFaultClient()
        client.reader = { request in page(request.run, from: request.offset, count: 2, end: request.offset + 2) }
        let store = RunLogStore(client: client); defer { store.close() }
        await store.select("run")
        XCTAssertEqual(client.tailRequests.map(\.offset), [2])
        client.publish(batch("run", from: 1, count: 3))
        try await wait { store.nextOffset == 4 }
        XCTAssertEqual(store.entries.map(\.offset), [0, 1, 2, 3])
        client.finish(throwing: CommandError(code: "connection_lost", message: "Connection lost"))
        try await wait { if case .unavailable = store.state { return true }; return false }
        await store.retry()
        XCTAssertEqual(client.requests.map(\.offset), [0, 4])
        XCTAssertEqual(client.tailRequests.map(\.offset), [2, 6])
        XCTAssertEqual(store.entries.map(\.offset), [0, 1, 2, 3, 4, 5])
        client.reader = { request in page(request.run, from: request.offset, count: 0, end: 6, complete: true) }
        client.finish()
        try await wait { store.isComplete == true && !store.isTailing }
        XCTAssertEqual(client.requests.last?.offset, 6)
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(client.eventSubscriptions, 0, "BoardSession alone owns application events")
    }
    @MainActor func testLateReadAndHiddenTailCannotPopulateAnotherSelection() async throws {
        let client = LogFaultClient()
        var late: CheckedContinuation<LogPage, Never>?
        client.reader = { request in
            if request.run == "old" { return await withCheckedContinuation { late = $0 } }
            return page(request.run, from: request.offset, count: 1, end: request.offset + 1)
        }
        let store = RunLogStore(client: client); defer { store.close() }
        let old = Task { await store.select("old") }
        try await wait { late != nil }
        await store.select("new")
        late?.resume(returning: page("old", from: 0, count: 3, end: 3)); await old.value
        XCTAssertEqual(store.runID, "new"); XCTAssertEqual(store.entries.map(\.offset), [0])
        let previousTail = try XCTUnwrap(client.tailRequests.last?.id)
        await store.setVisible(false)
        try await wait { client.terminations.contains(previousTail) }
        client.publish(batch("new", from: 1, count: 3), to: previousTail)
        XCTAssertEqual(store.nextOffset, 1); XCTAssertFalse(store.isTailing)
        await store.setVisible(true)
        XCTAssertEqual(client.requests.last?.offset, 1)
        XCTAssertEqual(store.entries.map(\.offset), [0, 1])
        XCTAssertEqual(client.tailRequests.last?.offset, 2)
        store.close()
        try await wait { client.terminations.count == 2 }
        XCTAssertNil(store.runID); XCTAssertTrue(store.entries.isEmpty)
    }
    @MainActor func testMemoryBudgetsEvictWithoutRenumberingAndLargeRecordRemainsReadable() async throws {
        let client = LogFaultClient(), large = String(repeating: "Full Unicode source 🐗\r\n", count: 4_000)
        client.reader = { request in
            if request.offset == 53 {
                return .init(batch: .init(runId: request.run, fromOffset: 53, nextOffset: 54,
                                         events: [.toolResult(id: "tool", ok: false, summary: large)]),
                             availableFromOffset: 0, endOffset: 54, isComplete: false)
            }
            return page(request.run, from: request.offset, count: 3, end: 3)
        }
        let limits = RunLogLimits(maximumRecords: 3, maximumBytes: 500, maximumLines: 12, pageSize: 3)
        let store = RunLogStore(client: client, limits: limits); defer { store.close() }
        await store.select("run")
        client.publish(batch("run", from: 3, count: 50))
        try await wait { store.nextOffset == 53 }
        XCTAssertEqual(store.entries.map(\.offset), [50, 51, 52])
        XCTAssertLessThanOrEqual(store.residentBytes, limits.maximumBytes)
        XCTAssertLessThanOrEqual(store.residentLines, limits.maximumLines)
        client.publish(.init(runId: "run", fromOffset: 53, nextOffset: 54,
                             events: [.toolResult(id: "tool", ok: false, summary: large)]))
        try await wait { store.nextOffset == 54 }
        let omitted = try XCTUnwrap(store.entries.last)
        XCTAssertNil(omitted.event); XCTAssertEqual(omitted.offset, 53); XCTAssertEqual(omitted.kind, .toolResult)
        XCTAssertGreaterThan(omitted.sourceBytes, limits.maximumBytes)
        XCTAssertGreaterThan(omitted.sourceLines, limits.maximumLines)
        let source = try await store.readFullRecord(at: 53)
        XCTAssertEqual(source, .toolResult(id: "tool", ok: false, summary: large))
        XCTAssertNil(store.entries.last?.event, "On-demand read must not bypass resident memory limits")
        XCTAssertLessThanOrEqual(store.residentBytes, limits.maximumBytes)
        XCTAssertLessThanOrEqual(store.residentLines, limits.maximumLines)
        let data = try await store.exportLoadedRecords()
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(exported.compactMap { $0["offset"] as? Int }, [51, 52])
    }
    @MainActor func testExpiredMissingAndEmptyLogsRemainDistinct() async throws {
        let client = LogFaultClient()
        client.reader = { request in
            if request.offset < 200 {
                throw CommandError(code: CommandError.logOffsetExpiredCode, message: "Trimmed",
                                   params: ["availableFromOffset": "200"])
            }
            return page(request.run, from: request.offset, count: 2, end: 202, complete: true, prefix: 200)
        }
        let store = RunLogStore(client: client); defer { store.close() }
        await store.select("run")
        XCTAssertEqual(store.state, .expired(availableFromOffset: 200))
        XCTAssertTrue(store.entries.isEmpty); XCTAssertEqual(store.nextOffset, 0)
        await store.readAvailablePrefix()
        XCTAssertEqual(store.entries.map(\.offset), [200, 201])
        XCTAssertEqual(store.availableFromOffset, 200); XCTAssertEqual(store.nextOffset, 202)
        client.reader = { _ in throw CommandError(code: CommandError.logUnavailableCode, message: "Deleted") }
        await store.retry()
        guard case .unavailable(let error) = store.state else { return XCTFail("Unavailable log became empty") }
        XCTAssertEqual(error.code, CommandError.logUnavailableCode)
        XCTAssertEqual(store.entries.map(\.offset), [200, 201], "Last confirmed fragment survives a read failure")
        client.reader = { request in page(request.run, from: 0, count: 0, end: 0, complete: true) }
        await store.select("empty")
        XCTAssertEqual(store.state, .ready); XCTAssertTrue(store.entries.isEmpty); XCTAssertEqual(store.isComplete, true)
        client.reader = { _ in throw CommandError(code: CommandError.logOffsetExpiredCode, message: "No prefix fact",
                                                 params: ["availableFromOffset": "-1"]) }
        await store.select("unknown-prefix")
        XCTAssertEqual(store.state, .expired(availableFromOffset: nil)); XCTAssertNil(store.availableFromOffset)
        let reads = client.requests.count
        await store.readAvailablePrefix()
        XCTAssertEqual(client.requests.count, reads, "Unknown prefix must not become an invented zero")
    }
    @MainActor func testForeignGapMalformedAndChangedPayloadsDoNotAdvanceCursor() async throws {
        for bad in [
            batch("foreign", from: 2, count: 1),
            batch("run", from: 3, count: 1),
            LogBatch(runId: "run", fromOffset: 2, nextOffset: 4, events: [logRecord(2)]),
            LogBatch(runId: "run", fromOffset: 0, nextOffset: 1, events: [.message(role: "assistant", text: "Changed immutable record")])
        ] {
            let client = LogFaultClient()
            client.reader = { request in page(request.run, from: 0, count: 2, end: 2) }
            let store = RunLogStore(client: client)
            await store.select("run"); client.publish(bad)
            try await wait { if case .unavailable = store.state { return true }; return false }
            XCTAssertEqual(store.nextOffset, 2); XCTAssertEqual(store.entries.map(\.offset), [0, 1])
            XCTAssertEqual(store.entries.first?.event, logRecord(0)); XCTAssertFalse(store.isTailing)
            store.close()
        }
        let client = LogFaultClient()
        client.reader = { request in .init(batch: batch("foreign", from: 0, count: 1),
                                          availableFromOffset: 0, endOffset: 1, isComplete: true) }
        let store = RunLogStore(client: client); defer { store.close() }
        await store.select("run")
        guard case .unavailable = store.state else { return XCTFail("Foreign initial read accepted") }
        XCTAssertTrue(store.entries.isEmpty); XCTAssertEqual(store.nextOffset, 0)
    }
    @MainActor func testEarlierWindowPausesTailAndLatestNavigationUsesServerEnd() async throws {
        let client = LogFaultClient()
        client.reader = { request in
            page(request.run, from: request.offset, count: Int(min(Int64(request.limit), 10 - request.offset)),
                 end: 10, complete: true)
        }
        let store = RunLogStore(client: client, limits: .init(maximumRecords: 5, maximumBytes: 4_096, maximumLines: 100, pageSize: 5))
        defer { store.close() }
        await store.select("run")
        try await wait { store.nextOffset == 10 && !store.isTailing && store.state == .ready }
        XCTAssertTrue(client.tailRequests.isEmpty, "Closed history must use sequential reads instead of overflowing a live stream")
        XCTAssertEqual(client.requests.prefix(2).map(\.offset), [0, 5])
        XCTAssertEqual(store.entries.map(\.offset), [5, 6, 7, 8, 9])
        await store.loadEarlier()
        XCTAssertEqual(store.mode, .history); XCTAssertFalse(store.isTailing)
        XCTAssertEqual(store.entries.map(\.offset), [0, 1, 2, 3, 4])
        XCTAssertEqual(store.nextOffset, 10); XCTAssertFalse(store.canLoadEarlier)
        await store.showLatest()
        XCTAssertEqual(store.mode, .latest); XCTAssertEqual(store.entries.map(\.offset), [5, 6, 7, 8, 9])
        XCTAssertEqual(client.requests.suffix(2).map(\.offset), [10, 5])
        XCTAssertEqual(store.nextOffset, 10); XCTAssertEqual(store.isComplete, true)
    }
    @MainActor func testBoardConnectionSuspendsAndResumesExactLogOffset() async throws {
        let client = LogFaultClient()
        client.reader = { request in page(request.run, from: request.offset, count: 1, end: request.offset + 1) }
        let store = RunLogStore(client: client); defer { store.close() }
        await store.select("run")
        let firstTail = try XCTUnwrap(client.tailRequests.last?.id)
        await store.setConnectionAvailable(false)
        try await wait { client.terminations.contains(firstTail) }
        XCTAssertEqual(store.state, .waitingForConnection); XCTAssertEqual(store.entries.map(\.offset), [0])
        await store.setConnectionAvailable(true)
        XCTAssertEqual(client.requests.last?.offset, 1); XCTAssertEqual(client.tailRequests.last?.offset, 2)
        XCTAssertEqual(store.entries.map(\.offset), [0, 1])
    }
    @MainActor func testCapabilityRemovalSuspendsReadsAndPreservesConfirmedFragment() async throws {
        let client = LogFaultClient()
        client.reader = { request in page(request.run, from: request.offset, count: 1, end: request.offset + 1) }
        let store = RunLogStore(client: client); defer { store.close() }
        await store.select("run")
        await store.setReadSupported(false)
        guard case .unavailable(let error) = store.state else { return XCTFail("Missing log capability was ignored") }
        XCTAssertEqual(error.code, CommandError.unsupportedOperationCode)
        XCTAssertEqual(store.entries.map(\.offset), [0]); XCTAssertFalse(store.isTailing)
        let reads = client.requests.count
        await store.retry()
        XCTAssertEqual(client.requests.count, reads)
        await store.setReadSupported(true)
        XCTAssertEqual(client.requests.last?.offset, 1)
        XCTAssertEqual(store.entries.map(\.offset), [0, 1]); XCTAssertTrue(store.isTailing)
    }
    @MainActor func testCleanStreamEndDoesNotInventCompletion() async throws {
        let client = LogFaultClient()
        client.reader = { request in
            page(request.run, from: request.offset, count: request.offset == 0 ? 1 : 0, end: 1)
        }
        let store = RunLogStore(client: client); defer { store.close() }
        await store.select("run"); client.finish()
        try await wait { if case .unavailable = store.state { return true }; return false }
        XCTAssertEqual(store.isComplete, false); XCTAssertEqual(store.nextOffset, 1)
        client.reader = { request in page(request.run, from: request.offset, count: 0, end: 1, complete: true) }
        await store.retry()
        XCTAssertEqual(store.state, .ready); XCTAssertEqual(store.isComplete, true); XCTAssertFalse(store.isTailing)
    }
    @MainActor func testLateFullRecordReadRejectsChangedRunOwner() async throws {
        let client = LogFaultClient()
        var pending: CheckedContinuation<LogPage, Never>?
        client.reader = { request in
            if request.run == "old" && request.limit == 1 { return await withCheckedContinuation { pending = $0 } }
            return page(request.run, from: 0, count: 1, end: 1, complete: true)
        }
        let store = RunLogStore(client: client); defer { store.close() }
        await store.select("old")
        let task = Task { try await store.readFullRecord(at: 0) }
        try await wait { pending != nil }
        await store.select("new")
        pending?.resume(returning: page("old", from: 0, count: 1, end: 1, complete: true))
        do { _ = try await task.value; XCTFail("Old source escaped its owner") } catch is CancellationError {}
        XCTAssertEqual(store.runID, "new"); XCTAssertEqual(store.entries.count, 1)
    }
}
private func logRecord(_ offset: Int64) -> AgentEvent { .message(role: "assistant", text: "record \(offset)") }
private func batch(_ run: RunID, from: Int64, count: Int) -> LogBatch {
    .init(runId: run, fromOffset: from, nextOffset: from + Int64(count), events: (0..<count).map { logRecord(from + Int64($0)) })
}
private func page(_ run: RunID, from: Int64, count: Int, end: Int64, complete: Bool = false, prefix: Int64 = 0) -> LogPage {
    .init(batch: batch(run, from: from, count: count), availableFromOffset: prefix, endOffset: end, isComplete: complete)
}
@MainActor private final class LogFaultClient: KabanClient {
    struct Read { let run: RunID; let offset: Int64; let limit: Int }
    struct Tail { let id: UUID; let run: RunID; let offset: Int64 }
    var requests: [Read] = [], tailRequests: [Tail] = [], terminations: [UUID] = []
    var eventSubscriptions = 0
    var reader: (Read) async throws -> LogPage = { request in page(request.run, from: request.offset, count: 0, end: request.offset, complete: true) }
    private var streams: [UUID: AsyncThrowingStream<LogBatch, Error>.Continuation] = [:]
    func getSnapshot() async throws -> Snapshot { Fix.snapshot() }
    func events() -> AsyncStream<EventEnvelope> { eventSubscriptions += 1; return AsyncStream { $0.finish() } }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        throw CommandError(code: CommandError.unsupportedOperationCode, message: "Read-only log fixture")
    }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: [.init(name: "readLog", supported: true)], commands: [])
    }
    func readLog(runId: RunID, fromOffset: Int64, limit: Int) async throws -> LogPage {
        let request = Read(run: runId, offset: fromOffset, limit: limit); requests.append(request)
        return try await reader(request)
    }
    func tailLog(runId: RunID, fromOffset: Int64) -> AsyncThrowingStream<LogBatch, Error> {
        let id = UUID(); tailRequests.append(.init(id: id, run: runId, offset: fromOffset))
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(2)) { continuation in
            streams[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.streams[id] = nil; self?.terminations.append(id) }
            }
        }
    }
    func publish(_ batch: LogBatch, to id: UUID? = nil) {
        guard let id = id ?? tailRequests.last?.id else { return }; streams[id]?.yield(batch)
    }
    func finish(throwing error: Error? = nil) {
        guard let id = tailRequests.last?.id else { return }; streams[id]?.finish(throwing: error)
    }
}
