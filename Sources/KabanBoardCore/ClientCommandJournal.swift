import Foundation
import KabanProtocol

/// The client's exact requests and receipts survive UI/session replacement. A correlated
/// event confirms a journal change, never completion of an external process or git effect.
@MainActor public final class ClientCommandJournal {
    public struct Record: Codable, Equatable, Sendable {
        public let envelope: CommandEnvelope
        public let sentAt: Date
        public var reply: CommandReply?
        public var eventSeq: Seq?
        public var deliveryUncertain: Bool
        public var isPending: Bool {
            if case .error = reply?.result { return false }
            return eventSeq == nil
        }
    }
    public private(set) var records: [Record]
    private let storage: any KeyValueStoring
    private let key: String
    public init(storage: any KeyValueStoring, key: String) throws {
        self.storage = storage; self.key = key
        records = try storage.data(forKey: key).map { try JSONDecoder().decode([Record].self, from: $0) } ?? []
    }
    public func begin(_ envelope: CommandEnvelope, at: Date = Date()) throws {
        if let existing = records.first(where: { $0.envelope.commandId == envelope.commandId }) {
            guard existing.envelope == envelope else { throw CommandError(code: "command_id_conflict", message: "Идентификатор команды уже занят.") }
            return
        }
        var next = records
        // Keep every unresolved request; retain only the latest 100 resolved receipts.
        let resolved = next.filter { !$0.isPending }.suffix(100)
        next = next.filter(\.isPending) + resolved
        next.append(.init(envelope: envelope, sentAt: at, reply: nil, eventSeq: nil, deliveryUncertain: false))
        try save(next)
    }
    public func receive(_ reply: CommandReply) throws {
        guard let index = records.firstIndex(where: { $0.envelope.commandId == reply.commandId }) else { return }
        var next = records
        next[index].reply = reply; next[index].deliveryUncertain = false
        try save(next)
    }
    public func observe(_ event: EventEnvelope) throws {
        guard let id = event.commandId, let index = records.firstIndex(where: { $0.envelope.commandId == id }) else { return }
        var next = records
        next[index].eventSeq = max(next[index].eventSeq ?? 0, event.seq)
        try save(next)
    }
    public func markUncertain(_ id: CommandID) throws {
        guard let index = records.firstIndex(where: { $0.envelope.commandId == id }) else { return }
        var next = records; next[index].deliveryUncertain = true
        try save(next)
    }
    private func save(_ next: [Record]) throws {
        let data = try JSONEncoder().encode(next)
        storage.set(data, forKey: key); records = next
    }
}
