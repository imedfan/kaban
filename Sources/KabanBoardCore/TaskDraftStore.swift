import Foundation
import KabanProtocol

public enum TaskDraftKey: Codable, Hashable, Sendable {
    case create(ProjectID)
    case edit(TaskID)
    case priority(TaskID)
}

/// User input has its own lifetime; reconnect never submits a draft.
@MainActor public final class TaskDraftStore {
    public struct Record: Codable, Equatable, Sendable {
        public var key: TaskDraftKey
        public var draft: DemoTaskDraft
        public var exactBody: String?
        public var baseCard: TaskCard?
        public var submittedBy: CommandID?
        public var priorityText: String?
        public init(key: TaskDraftKey, draft: DemoTaskDraft, exactBody: String? = nil, baseCard: TaskCard? = nil, submittedBy: CommandID? = nil, priorityText: String? = nil) {
            self.key = key; self.draft = draft; self.exactBody = exactBody
            self.baseCard = baseCard; self.submittedBy = submittedBy; self.priorityText = priorityText
        }
    }
    /// Uses the card the user reviewed. The receiver still validates any race after this check.
    public func editCommand(for key: TaskDraftKey, current: TaskCard?, bodyIsKnown: Bool) -> Command? {
        guard case .edit(let id) = key, let record = record(for: key), let current,
              current.id == id, record.baseCard == current, TaskActions.canEdit(current),
              record.draft.canSubmit else { return nil }
        return .editTask(taskId: id, title: record.draft.title, body: bodyIsKnown ? record.exactBody : nil)
    }
    public private(set) var records: [Record]
    private let storage: any KeyValueStoring
    private let key: String
    public init(storage: any KeyValueStoring, key: String) throws {
        self.storage = storage; self.key = key
        records = try storage.data(forKey: key).map { try JSONDecoder().decode([Record].self, from: $0) } ?? []
    }
    public func record(for key: TaskDraftKey) -> Record? { records.first { $0.key == key } }
    public func save(_ record: Record) throws {
        var next = records.filter { $0.key != record.key }; next.append(record)
        try persist(next)
    }
    public func submitted(_ key: TaskDraftKey, by id: CommandID) throws {
        guard var record = record(for: key) else { return }
        record.submittedBy = id; try save(record)
    }
    /// A late old confirmation cannot discard a new draft in the same form.
    public func confirmed(_ id: CommandID) throws {
        try persist(records.filter { $0.submittedBy != id })
    }
    public func discard(_ key: TaskDraftKey) throws { try persist(records.filter { $0.key != key }) }
    private func persist(_ next: [Record]) throws {
        storage.set(try JSONEncoder().encode(next), forKey: key); records = next
    }
}
