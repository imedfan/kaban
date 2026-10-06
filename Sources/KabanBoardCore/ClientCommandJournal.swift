import Foundation
import KabanProtocol

/// Exact requests and receipts survive UI/session replacement. Resolution needs
/// the command's own event or receipt covered by an authoritative snapshot;
/// snapshot coverage never completes an external git action.
@MainActor public final class ClientCommandJournal {
    public struct Record: Codable, Equatable, Sendable {
        public let envelope: CommandEnvelope
        public let sentAt: Date
        public var reply: CommandReply?
        public var eventSeq: Seq?
        public var deliveryUncertain: Bool
        // Optional fields preserve journals written before reconciliation existed.
        public var confirmedSeq: Seq? = nil
        public var coveredSnapshotSeq: Seq? = nil
        public var createdTaskID: TaskID? = nil
        public var effectError: CommandError? = nil
        public var effectSuperseded: Bool? = nil
        public var scope: CommandScope? { envelope.command.mutationScope }
        public var phase: ClientCommandPhase {
            if let effectError { return .effectFailed(effectError) }
            if effectSuperseded == true { return .superseded }
            if confirmedSeq != nil { return .applied }
            if case .error(let error) = reply?.result { return .rejected(error) }
            if case .validationIssues = reply?.result { return .rejected(.init(code: "validation_failed", message: "Проверка настроек выявила ошибки.")) }
            if deliveryUncertain { return .deliveryUncertain }
            guard reply != nil else { return .sending }
            return envelope.command.awaitsExternalCompletion ? .awaitingEffect : .awaitingEvent
        }
        public var isPending: Bool {
            switch phase {
            case .applied, .rejected, .effectFailed, .superseded: false
            default: true
            }
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
        guard envelope.command.mutationScope != nil else {
            throw CommandError(code: "invalid_request", message: "Запрос чтения не является сохраняемой операцией.")
        }
        let resolved = records.filter { !$0.isPending }.suffix(100)
        var next = records.filter(\.isPending) + resolved
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
        if next[index].envelope.command.isConfirmed(by: event.event) {
            next[index].confirmedSeq = max(next[index].confirmedSeq ?? 0, event.seq)
            next[index].deliveryUncertain = false
            if case .taskCreated(let card) = event.event { next[index].createdTaskID = card.id }
        }
        try save(next)
    }
    /// Replay may return a receipt whose event has left retention. Applying the
    /// snapshot covering that receipt proves the durable mutation, without
    /// modifying any card locally. Restore receipts only reserve an effect.
    public func confirmThrough(snapshotSeq: Seq) throws {
        var next = records
        for index in next.indices {
            guard next[index].isPending, !next[index].envelope.command.awaitsExternalCompletion,
                  let seq = next[index].reply?.seq, seq > 0, seq <= snapshotSeq,
                  next[index].reply?.result != nil else { continue }
            if case .error = next[index].reply?.result { continue }
            next[index].confirmedSeq = seq
            next[index].coveredSnapshotSeq = snapshotSeq
            next[index].deliveryUncertain = false
        }
        if next != records { try save(next) }
    }
    /// An authoritative detail may outlive journal retention. Match the exact
    /// intent, including run/ref; never parse private feed IDs or human text.
    public func observeRestores(in detail: TaskDetail) throws {
        guard let operations = detail.wipRestoreOperations else { return }
        var next = records
        for index in next.indices {
            guard next[index].isPending,
                  case .restoreWIP(let task, let run, let ref) = next[index].envelope.command,
                  task == detail.task.id,
                  let operation = operations.first(where: { $0.commandId == next[index].envelope.commandId && $0.runId == run && $0.wipRef == ref }) else { continue }
            switch operation.status {
            case .pending: continue
            case .succeeded, .failed:
                guard let seq = operation.completedSeq, seq > 0, seq <= detail.seq else { continue }
                if operation.status == .succeeded { next[index].confirmedSeq = seq }
                else { next[index].effectError = .init(code: "wip_restore_failed", message: operation.message ?? "Не удалось восстановить WIP.") }
            case .superseded: next[index].effectSuperseded = true
            }
            next[index].coveredSnapshotSeq = detail.seq
            next[index].deliveryUncertain = false
        }
        if next != records { try save(next) }
    }
    public func markUncertain(_ id: CommandID) throws {
        guard let index = records.firstIndex(where: { $0.envelope.commandId == id }), records[index].isPending else { return }
        var next = records; next[index].deliveryUncertain = true
        try save(next)
    }
    private func save(_ next: [Record]) throws {
        let data = try JSONEncoder().encode(next)
        storage.set(data, forKey: key); records = next
    }
}
