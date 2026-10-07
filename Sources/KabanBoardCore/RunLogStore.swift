import Foundation
import Observation
import KabanProtocol

public struct RunLogLimits: Sendable {
    public let maximumRecords: Int
    public let maximumBytes: Int
    public let maximumLines: Int
    public let pageSize: Int
    public let maximumRecordBytes: Int
    public let maximumRecordLines: Int
    public init(maximumRecords: Int = 50_000, maximumBytes: Int = 8 * 1024 * 1024,
                maximumLines: Int = 50_000, pageSize: Int = 100,
                maximumRecordBytes: Int = 256 * 1024, maximumRecordLines: Int = 5_000) {
        precondition(maximumRecords > 0 && maximumBytes >= 256 && maximumLines >= 4)
        precondition((1...DaemonWire.maxPageSize).contains(pageSize))
        precondition(maximumRecordBytes > 0 && maximumRecordLines > 0)
        self.maximumRecords = maximumRecords; self.maximumBytes = maximumBytes
        self.maximumLines = maximumLines; self.pageSize = pageSize
        self.maximumRecordBytes = maximumRecordBytes; self.maximumRecordLines = maximumRecordLines
    }
}
public enum RunLogState: Equatable, Sendable {
    case idle, loading, ready, waitingForConnection
    case expired(availableFromOffset: Int64?)
    case unavailable(CommandError)
}
public enum RunLogMode: Equatable, Sendable { case latest, history }
public enum LogEventKind: Sendable, Hashable {
    case initialized, message, toolCall, toolResult, usage, error, result
}
/// IDs remain daemon record offsets even after eviction, retention and reconnect.
public struct RunLogEntry: Identifiable, Hashable, Sendable {
    public var id: Int64 { offset }
    public let offset: Int64
    public let event: AgentEvent?
    public let kind: LogEventKind
    public let sourceBytes: Int
    public let sourceLines: Int
    public var requiresSeparateRead: Bool { event == nil }
    let signature: Int
    var residentBytes: Int { event == nil ? 128 : sourceBytes }
    var residentLines: Int { event == nil ? 4 : sourceLines }

    init(offset: Int64, event: AgentEvent, limits: RunLogLimits) throws {
        self.offset = offset
        sourceBytes = try KabanCoding.makeEncoder().encode(event).count
        let texts: [String]
        switch event {
        case .initialized(let model, let session): kind = .initialized; texts = [model ?? "", session ?? ""]
        case .message(let role, let text): kind = .message; texts = [role, text]
        case .toolCall(let id, let name, let summary): kind = .toolCall; texts = [id, name, summary]
        case .toolResult(let id, _, let summary): kind = .toolResult; texts = [id, summary]
        case .usage: kind = .usage; texts = []
        case .error(let code, let message): kind = .error; texts = [code ?? "", message]
        case .result: kind = .result; texts = []
        }
        sourceLines = max(2, texts.reduce(2) { count, text in count + 1 + text.utf8.lazy.filter { $0 == 10 }.count })
        signature = event.hashValue // In-memory duplicate check, never a persisted/security digest.
        self.event = sourceBytes > min(limits.maximumBytes, limits.maximumRecordBytes) || sourceLines > min(limits.maximumLines, limits.maximumRecordLines) ? nil : event
    }
}

/// One selected run. BoardSession remains the only owner of the application's update stream.
@MainActor @Observable public final class RunLogStore {
    public private(set) var runID: RunID?
    public private(set) var entries: [RunLogEntry] = []
    public private(set) var state: RunLogState = .idle
    public private(set) var mode: RunLogMode = .latest
    public private(set) var availableFromOffset: Int64?
    public private(set) var endOffset: Int64?
    public private(set) var nextOffset: Int64 = 0
    public private(set) var isComplete: Bool?
    public private(set) var isTailing = false
    public private(set) var isVisible = false
    public private(set) var residentBytes = 0
    public private(set) var residentLines = 0
    public private(set) var revision = 0
    public let limits: RunLogLimits
    public var canLoadEarlier: Bool {
        guard let first = entries.first?.offset, let availableFromOffset else { return false }
        return first > availableFromOffset && state != .loading
    }
    private let client: any KabanClient
    private var generation = UUID()
    @ObservationIgnored private var tail: Task<Void, Never>?
    private var connected = true
    private var supported = true
    private enum Placement { case append, replace, prepend }

    public init(client: any KabanClient, limits: RunLogLimits = .init()) {
        self.client = client; self.limits = limits
    }
    deinit { tail?.cancel() }

    public func select(_ id: RunID?, visible: Bool = true) async {
        invalidate(); runID = id; isVisible = visible
        mode = .latest; entries = []; residentBytes = 0; residentLines = 0
        availableFromOffset = nil; endOffset = nil; isComplete = nil; nextOffset = 0
        state = .idle; revision += 1
        guard id != nil, visible else { return }
        guard accessAvailable() else { return }
        await fetch(from: 0, placement: .replace, owner: generation, startTail: true)
    }
    public func close() {
        invalidate(); runID = nil; isVisible = false; entries = []
        residentBytes = 0; residentLines = 0; availableFromOffset = nil; endOffset = nil
        isComplete = nil; nextOffset = 0; state = .idle; mode = .latest; revision += 1
    }
    public func setVisible(_ visible: Bool) async {
        guard isVisible != visible else { return }
        invalidate(); isVisible = visible
        if visible { await retry() }
    }
    public func setConnectionAvailable(_ value: Bool) async {
        guard connected != value else { return }
        invalidate(); connected = value
        guard runID != nil, isVisible else { return }
        if value { await retry() } else { state = .waitingForConnection }
    }
    public func setReadSupported(_ value: Bool) async {
        guard supported != value else { return }
        invalidate(); supported = value
        guard runID != nil, isVisible else { return }
        if value { await retry() }
        else { state = .unavailable(.init(code: CommandError.unsupportedOperationCode,
                                          message: "Источник не подтвердил поддержку чтения логов.")) }
    }
    private func accessAvailable() -> Bool {
        guard connected else { state = .waitingForConnection; return false }
        guard supported else {
            state = .unavailable(.init(code: CommandError.unsupportedOperationCode,
                                       message: "Источник не подтвердил поддержку чтения логов."))
            return false
        }
        return true
    }
    /// Resume from the last consumed offset, never from an inferred card timestamp.
    public func retry() async {
        guard runID != nil, isVisible else { return }
        invalidate()
        guard accessAvailable() else { return }
        if mode == .history {
            await fetch(from: entries.first?.offset ?? nextOffset, placement: .replace, owner: generation, startTail: false)
        } else {
            await fetch(from: nextOffset, placement: .append, owner: generation, startTail: true)
        }
    }
    /// Explicit user acknowledgement of a trimmed prefix. Missing error params stay unknown.
    public func readAvailablePrefix() async {
        guard case .expired(let start?) = state, runID != nil, isVisible else { return }
        invalidate(); mode = .latest
        guard accessAvailable() else { return }
        await fetch(from: start, placement: .replace, owner: generation, startTail: true)
    }
    public func loadEarlier() async {
        guard canLoadEarlier, let first = entries.first?.offset, let prefix = availableFromOffset, isVisible else { return }
        invalidate(); mode = .history
        guard accessAvailable() else { return }
        let from = max(prefix, first - Int64(limits.pageSize))
        await fetch(from: from, placement: .prepend, owner: generation, startTail: false,
                    requestedLimit: Int(first - from))
    }
    /// An explicit navigation to the latest available window may skip unseen older records.
    public func showLatest() async {
        guard let id = runID, isVisible else { return }
        invalidate(); let owner = generation
        guard accessAvailable() else { return }
        state = .loading
        do {
            let probe = try await client.readLog(runId: id, fromOffset: nextOffset, limit: 1)
            try validate(probe, id: id, from: nextOffset, limit: 1)
            guard matches(owner) else { return }
            let from = max(probe.availableFromOffset, probe.endOffset - Int64(limits.pageSize))
            mode = .latest
            await fetch(from: from, placement: .replace, owner: owner, startTail: true)
        } catch { fail(error, owner: owner) }
    }
    /// Large records are re-read individually on demand. Paths/raw files never enter this reader.
    public func readFullRecord(at offset: Int64) async throws -> AgentEvent {
        guard let id = runID, isVisible, connected, supported, entries.contains(where: { $0.offset == offset }) else { throw CancellationError() }
        let owner = generation
        let page = try await client.readLog(runId: id, fromOffset: offset, limit: 1)
        try validate(page, id: id, from: offset, limit: 1)
        guard matches(owner), let event = page.batch.events.first else { throw CancellationError() }
        return event
    }
    /// Export exactly the loaded normalized payloads; omitted records require a separate read.
    public func exportLoadedRecords() throws -> Data {
        struct Record: Encodable { let offset: Int64; let event: AgentEvent }
        let records = entries.compactMap { entry in entry.event.map { Record(offset: entry.offset, event: $0) } }
        return try KabanCoding.makeEncoder().encode(records)
    }
    private func invalidate() {
        generation = UUID(); tail?.cancel(); tail = nil; isTailing = false
    }
    private func matches(_ owner: UUID) -> Bool {
        owner == generation && runID != nil && isVisible && connected && supported && !Task.isCancelled
    }
    private func fetch(from: Int64, placement: Placement, owner: UUID, startTail: Bool, requestedLimit: Int? = nil) async {
        guard let id = runID, matches(owner) else { return }
        let limit = requestedLimit ?? limits.pageSize
        state = .loading
        do {
            let page = try await client.readLog(runId: id, fromOffset: from, limit: limit)
            try validate(page, id: id, from: from, limit: limit)
            let prepared = try await prepare(page.batch)
            guard matches(owner) else { return }
            availableFromOffset = page.availableFromOffset; endOffset = page.endOffset; isComplete = page.isComplete
            switch placement {
            case .replace:
                entries = prepared; nextOffset = page.batch.nextOffset; recount()
            case .append:
                try append(prepared, batch: page.batch)
            case .prepend:
                guard page.batch.nextOffset == entries.first?.offset else { throw invalid("Ранняя страница не примыкает к открытому фрагменту.") }
                entries.insert(contentsOf: prepared, at: 0); recount()
            }
            trim(fromFront: mode == .latest); revision += 1; state = .ready
            if startTail, mode == .latest, !(page.isComplete && nextOffset == page.endOffset) { beginTail(owner) }
        } catch { fail(error, owner: owner) }
    }
    private func validate(_ page: LogPage, id: RunID, from: Int64, limit: Int) throws {
        guard page.batch.runId == id, page.batch.fromOffset == from,
              page.availableFromOffset >= 0, page.availableFromOffset <= from,
              page.endOffset >= from, page.batch.nextOffset <= page.endOffset,
              !page.batch.events.isEmpty || from == page.endOffset else { throw invalid("Некорректная страница лога.") }
        try validate(page.batch, id: id, limit: limit)
    }
    private func validate(_ batch: LogBatch, id: RunID, limit: Int = DaemonWire.maxPageSize) throws {
        guard batch.runId == id, batch.fromOffset >= 0, batch.nextOffset >= batch.fromOffset,
              batch.nextOffset - batch.fromOffset == Int64(batch.events.count),
              batch.events.count <= limit else { throw invalid("Некорректные смещения лога.") }
    }
    /// Encoding/line counting of large output happens outside the UI actor.
    private func prepare(_ batch: LogBatch) async throws -> [RunLogEntry] {
        let limits = limits
        return try await Task.detached(priority: .userInitiated) {
            try batch.events.enumerated().map { index, event in
                try RunLogEntry(offset: batch.fromOffset + Int64(index), event: event, limits: limits)
            }
        }.value
    }
    private func append(_ prepared: [RunLogEntry], batch: LogBatch) throws {
        guard batch.fromOffset <= nextOffset else { throw invalid("В логе пропущены записи. Повторите чтение с последнего смещения.") }
        if let first = entries.first?.offset {
            for entry in prepared where entry.offset >= first && entry.offset < nextOffset {
                let index = Int(entry.offset - first)
                if entries.indices.contains(index), entries[index].offset == entry.offset,
                   entries[index].signature != entry.signature { throw invalid("Служба изменила уже полученную запись лога.") }
            }
        }
        let fresh = prepared.filter { $0.offset >= nextOffset }
        entries.append(contentsOf: fresh)
        residentBytes += fresh.reduce(0) { $0 + $1.residentBytes }
        residentLines += fresh.reduce(0) { $0 + $1.residentLines }
        nextOffset = max(nextOffset, batch.nextOffset)
        endOffset = max(endOffset ?? 0, batch.nextOffset)
    }
    private func recount() {
        residentBytes = entries.reduce(0) { $0 + $1.residentBytes }
        residentLines = entries.reduce(0) { $0 + $1.residentLines }
    }
    private func trim(fromFront: Bool) {
        var count = 0
        while entries.count - count > limits.maximumRecords || residentBytes > limits.maximumBytes || residentLines > limits.maximumLines {
            let index = fromFront ? count : entries.count - count - 1
            guard entries.indices.contains(index) else { break }
            residentBytes -= entries[index].residentBytes; residentLines -= entries[index].residentLines; count += 1
        }
        if count > 0 {
            if fromFront { entries.removeFirst(count) } else { entries.removeLast(count) }
        }
    }
    private func beginTail(_ owner: UUID) {
        guard let id = runID, matches(owner), tail == nil else { return }
        let stream = client.tailLog(runId: id, fromOffset: nextOffset)
        isTailing = true
        tail = Task { [weak self] in
            do {
                for try await batch in stream {
                    guard let self, self.matches(owner) else { return }
                    try self.validate(batch, id: id)
                    let prepared = try await self.prepare(batch)
                    guard self.matches(owner) else { return }
                    try self.append(prepared, batch: batch)
                    self.trim(fromFront: true); self.revision += 1; self.state = .ready
                }
                guard let self, self.matches(owner) else { return }
                self.tail = nil; self.isTailing = false
                await self.fetch(from: self.nextOffset, placement: .append, owner: owner, startTail: false)
                if self.matches(owner), self.state == .ready,
                   !(self.isComplete == true && self.nextOffset == self.endOffset) {
                    self.state = .unavailable(self.invalid("Поток лога завершился до конца. Повторите чтение."))
                }
            } catch { self?.fail(error, owner: owner) }
        }
    }
    private func fail(_ error: Error, owner: UUID) {
        guard matches(owner) else { return }
        tail?.cancel(); tail = nil; isTailing = false
        let failure = (error as? CommandError) ?? .init(code: "log_read_failed", message: error.localizedDescription)
        if failure.code == CommandError.logOffsetExpiredCode {
            let prefix = failure.params["availableFromOffset"].flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
            availableFromOffset = prefix; state = .expired(availableFromOffset: prefix)
        } else { state = .unavailable(failure) }
    }
    private func invalid(_ message: String) -> CommandError { .init(code: "invalid_log_reply", message: message) }
}
