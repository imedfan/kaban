import Foundation
import Observation
import KabanProtocol
import KabanBoardCore

final class DefaultsStorage: KeyValueStoring, @unchecked Sendable {
    func data(forKey key: String) -> Data? { UserDefaults.standard.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) { UserDefaults.standard.set(data, forKey: key) }
}

@MainActor @Observable final class BoardStore {
    private let client: any KabanClient
    private let boardSet = BoardSetStore(storage: DefaultsStorage())
    var projection: BoardProjection?
    var visibleIDs: [ProjectID] = []
    var selectedID: TaskID?
    var detail: TaskDetail?
    var error: String?
    private var didConnect = false

    init(client: any KabanClient) { self.client = client }
    func connect() async {
        guard !didConnect else { return }
        didConnect = true
        let stream = client.events()
        do {
            let snapshot = try await client.getSnapshot()
            projection = BoardProjection(snapshot: snapshot)
            boardSet.bootstrap(projects: snapshot.projects.map(\.id))
            visibleIDs = boardSet.visibleProjectIds
            for await event in stream {
                guard !Task.isCancelled else { break }
                guard var board = projection else { continue }
                let result = board.apply(event)
                if case .gap = result { board.replace(with: try await client.getSnapshot()) }
                boardSet.apply(event.event)
                projection = board
                visibleIDs = boardSet.visibleProjectIds
                if let id = selectedID { await select(id) }
            }
        } catch { self.error = error.localizedDescription }
        didConnect = false
    }
    func select(_ id: TaskID?) async {
        selectedID = id
        detail = nil
        guard let id else { return }
        do {
            let result = try await client.send(.getTaskDetail(taskId: id), commandId: UUID())
            guard selectedID == id else { return }
            switch result {
            case .taskDetail(let detail): self.detail = detail
            case .error(let error): self.error = error.message
            default: self.error = "Не удалось получить детали задачи."
            }
        } catch { self.error = error.localizedDescription }
    }
    func send(_ command: Command, taskID: TaskID) async {
        let commandID = UUID()
        projection?.markSent(commandId: commandID, taskId: taskID, at: Date())
        do {
            if case .error(let error) = try await client.send(command, commandId: commandID) {
                projection?.noteCommandError(commandID)
                self.error = error.message
            }
        } catch {
            projection?.noteCommandError(commandID)
            self.error = error.localizedDescription
        }
    }
    func hide(_ id: ProjectID) { boardSet.hide(id); visibleIDs = boardSet.visibleProjectIds }
    func show(_ id: ProjectID) { boardSet.show(id); visibleIDs = boardSet.visibleProjectIds }
}
