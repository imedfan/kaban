import Foundation
import KabanProtocol

/// One bounded volatile channel per service incarnation. Nothing here allocates a durable seq.
/// The lock serializes publishing with replacement snapshots, never with an external process.
public final class DaemonLiveEvents: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionId = UUID()
    private var offset: Int64 = 0
    private struct Retained { let envelope: EphemeralEnvelope; let bytes: Int }
    private var buffer: [Retained] = []
    private var current: [String: Retained] = [:]
    private var bufferBytes = 0
    private var currentBytes = 0
    private let capacity: Int
    private let maxBytes: Int

    public init(capacity: Int = DaemonWire.maxPageSize * 2, maxBytes: Int = DaemonWire.maxMessageBytes / 2) {
        precondition(capacity > 0 && maxBytes > 0)
        self.capacity = capacity; self.maxBytes = maxBytes
    }
    private var cursor: EphemeralCursor { .init(sessionId: sessionId, offset: offset) }

    /// A producer cleared its durable sample. Replacement must not reintroduce an old
    /// retained value; the service follows this with the existing resyncRequired event.
    func discardQuota() {
        lock.withLock {
            if let previous = current.removeValue(forKey: "quota") { currentBytes -= previous.bytes }
        }
    }

    func synchronize(snapshot: () throws -> Snapshot) throws -> SnapshotReplacement {
        try lock.withLock {
            let state = try snapshot()
            let values = current.values.map(\.envelope).filter {
                // Durable settingsChanged may have superseded a live flag value while the
                // producer was idle. The authoritative replacement must not restore old flags.
                if case .schedulerFlagsChanged = $0.event { return $0.afterSeq == state.seq }
                return true
            }.sorted { $0.cursor.offset < $1.cursor.offset }
            return .init(snapshot: state, cursor: cursor, current: values)
        }
    }
    func publish(_ event: EphemeralEvent, at: Date, latestSeq: () throws -> Seq) throws {
        try lock.withLock {
            let key = Self.key(event)
            guard offset < Int64.max, key == nil || current[key!] != nil || current.count < capacity else {
                throw DaemonTransportError.bufferOverflow
            }
            let seq = try latestSeq()
            let envelope = EphemeralEnvelope(cursor: .init(sessionId: sessionId, offset: offset + 1), afterSeq: seq, at: at, event: event)
            let bytes = try DaemonWire.encode(envelope).count
            let previousBytes = key.flatMap { current[$0]?.bytes } ?? 0
            guard bytes <= maxBytes, key == nil || currentBytes - previousBytes + bytes <= maxBytes else {
                throw DaemonTransportError.payloadTooLarge
            }
            offset += 1
            let retained = Retained(envelope: envelope, bytes: bytes)
            buffer.append(retained); bufferBytes += bytes
            while buffer.count > capacity || bufferBytes > maxBytes { bufferBytes -= buffer.removeFirst().bytes }
            if let key { current[key] = retained; currentBytes += bytes - previousBytes }
        }
    }
    func page(after: EphemeralCursor, limit: Int) throws -> EphemeralPage {
        guard after.offset >= 0, (1...DaemonWire.maxPageSize).contains(limit) else {
            throw CommandError(code: "invalid_request", message: "Некорректный курсор или размер эфирного пакета.")
        }
        return lock.withLock {
            let earliest = buffer.first.map { $0.envelope.cursor.offset - 1 } ?? offset
            guard after.sessionId == sessionId, (earliest...offset).contains(after.offset) else {
                return .init(fromCursor: after, nextCursor: cursor, latestCursor: cursor, events: [], resetRequired: true)
            }
            let events = Array(buffer.lazy.map(\.envelope).filter { $0.cursor.offset > after.offset }.prefix(limit))
            return .init(fromCursor: after, nextCursor: events.last?.cursor ?? after, latestCursor: cursor, events: events)
        }
    }
    private static func key(_ event: EphemeralEvent) -> String? {
        switch event {
        case .schedulerFlagsChanged: "schedulerFlags"
        case .modelFlagsChanged: "modelFlags"
        case .quotaUpdated: "quota"
        case .modelCatalogChanged: "catalog"
        case .runnerChecked: "runner"
        case .pipelineDraftValidated(let draft): "draft:\(draft.projectId)"
        case .runProgress(let progress): "progress:\(progress.taskId)"
        case .resyncRequired, .unknown: nil
        }
    }
}
