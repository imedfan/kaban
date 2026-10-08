import Foundation
import Observation
import KabanProtocol

public enum IncidentReadState: Equatable, Sendable { case unknown, loading, loaded, failed(String) }

@MainActor @Observable public final class IncidentsStore {
    public struct ReadKey: Equatable, Sendable {
        let generation: UUID
        let revision: UUID
        let available: Bool
    }
    public private(set) var records: [Incident] = []
    public private(set) var readState: IncidentReadState = .unknown
    public var filter: IncidentListState = .open
    public var selectedID: IncidentID?
    private let client: any KabanClient
    private let session: BoardSession
    private var readID = UUID()
    private var loadedKey: ReadKey?
    private var scheduled: Task<Void, Never>?
    private var workerID = UUID()
    private var needsRead = false

    public init(client: any KabanClient, session: BoardSession) { self.client = client; self.session = session }
    public var readKey: ReadKey {
        .init(generation: session.sessionGeneration, revision: session.incidentReadRevision, available: session.can(.listIncidents))
    }
    public var isCurrent: Bool { readState == .loaded && loadedKey == readKey }
    public var selected: Incident? { records.first { $0.id == selectedID } }
    public var visible: [Incident] {
        records.filter { filter == .all || $0.resolvedAt == nil }.sorted {
            if ($0.resolvedAt == nil) != ($1.resolvedAt == nil) { return $0.resolvedAt == nil }
            if $0.openedAt != $1.openedAt { return $0.openedAt > $1.openedAt }
            return $0.id.rawValue < $1.id.rawValue
        }
    }
    public func forTask(_ id: TaskID) -> [Incident] { records.filter { $0.taskId == id } }
    public func scheduleRefresh() {
        needsRead = true
        guard scheduled == nil else { return }
        let worker = UUID(); workerID = worker
        scheduled = Task { [weak self] in
            while !Task.isCancelled, let self, self.needsRead {
                self.needsRead = false
                await self.refresh()
            }
            if self?.workerID == worker { self?.scheduled = nil }
        }
    }
    public func refresh() async {
        let token = UUID(); readID = token
        let key = readKey
        guard key.available else {
            readState = .failed("Чтение инцидентов недоступно. Подключитесь к службе с поддержкой этой команды.")
            return
        }
        readState = .loading
        let envelope = CommandEnvelope(command: .listIncidents(projectIds: nil, state: .all))
        do {
            let reply = try await client.send(envelope)
            guard token == readID else { return }
            guard !Task.isCancelled, key == readKey else { invalidateRead(); return }
            guard reply.commandId == envelope.commandId else { throw CommandError(code: "invalid_reply", message: "Список относится к другому запросу.") }
            if case .error(let error) = reply.result { throw error }
            guard case .incidents(let values) = reply.result, Set(values.map(\.id)).count == values.count else {
                throw CommandError(code: "invalid_reply", message: "Служба не вернула корректный список инцидентов.")
            }
            records = values; loadedKey = key; readState = .loaded
        } catch {
            guard token == readID else { return }
            guard !Task.isCancelled, key == readKey else { invalidateRead(); return }
            readState = .failed((error as? CommandError)?.message ?? "Не удалось прочитать инциденты. Повторите запрос.")
        }
    }
    public func stop() {
        needsRead = false; readID = UUID(); workerID = UUID()
        scheduled?.cancel(); scheduled = nil; readState = .unknown
    }
    private func invalidateRead() {
        readState = .unknown
        if readKey.available { needsRead = true }
    }
}
