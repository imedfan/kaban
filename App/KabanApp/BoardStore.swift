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
    private let boardSet: BoardSetStore
    var screen: BoardScreen = .board
    var filter: BoardFilter = .all
    var query = ""
    var searchRequest = 0
    var sheet: TaskSheetRoute?
    var qaLayoutRevision = 0
    var projection: BoardProjection?
    var visibleIDs: [ProjectID] = []
    var selectedProjectID: ProjectID?
    var selectedID: TaskID?
    var detail: TaskDetail?
    var error: String?
    var editorError: String?
    private(set) var creation = TaskCreationPending()
    private(set) var createdTaskID: TaskID?
    private var selection = TaskDetailSelection()
    private var taskReadFloors: [TaskID: Seq] = [:]
    private var didConnect = false

    init(client: any KabanClient, storage: any KeyValueStoring = DefaultsStorage()) {
        self.client = client
        self.boardSet = BoardSetStore(storage: storage)
    }
    func connect() async {
        guard !didConnect else { return }
        didConnect = true
        let stream = client.events()
        do {
            let snapshot = try await client.getSnapshot()
            projection = BoardProjection(snapshot: snapshot)
            taskReadFloors = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, snapshot.seq) })
            boardSet.bootstrap(projects: snapshot.projects.map(\.id))
            visibleIDs = boardSet.visibleProjectIds
            selectedProjectID = snapshot.projects.first?.id
            for await event in stream {
                guard !Task.isCancelled else { break }
                guard var board = projection else { continue }
                let result = board.apply(event)
                if case .gap = result {
                    let snapshot = try await client.getSnapshot()
                    board.replace(with: snapshot)
                    taskReadFloors = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, snapshot.seq) })
                    projection = board
                    boardSet.bootstrap(projects: board.projectOrder)
                    visibleIDs = boardSet.visibleProjectIds
                    if selectedProjectID == nil || selectedProjectID.map({ board.projects[$0] == nil }) == true { selectedProjectID = board.projectOrder.first }
                    if let id = creation.commandID { creation.fail(id); editorError = "Доска обновлена. Проверьте, была ли создана задача." }
                    // Invalidate older detail requests, including same-task body responses.
                    if let id = selectedID { await select(board.tasks[id] == nil ? nil : id) }
                    continue
                }
                projection = board
                guard result == .applied else { continue }
                switch event.event {
                case .taskCreated(let card), .taskEdited(let card), .taskUpdated(let card): taskReadFloors[card.id] = event.seq
                default: break
                }
                boardSet.apply(event.event)
                visibleIDs = boardSet.visibleProjectIds
                if selectedProjectID == nil || selectedProjectID.map({ board.projects[$0] == nil }) == true { selectedProjectID = board.projectOrder.first }
                if let id = creation.finish(with: event) {
                    createdTaskID = id
                    if let project = board.tasks[id]?.projectId { show(project); selectedProjectID = project }
                    Task { await select(id) }
                } else if let id = selectedID {
                    if board.tasks[id] == nil { await select(nil) }
                    else {
                        switch event.event {
                        case .taskUpdated(let card) where card.id == id, .taskEdited(let card) where card.id == id:
                            Task { await refreshDetail(id) }
                        default: break
                        }
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
        didConnect = false
    }
    func select(_ id: TaskID?) async {
        selectedID = id
        detail = nil
        _ = selection.begin(id)
        if let id { await refreshDetail(id) }
    }
    private func refreshDetail(_ id: TaskID) async {
        guard selectedID == id else { return }
        let generation = selection.begin(id)
        do {
            let result = try await client.send(.getTaskDetail(taskId: id), commandId: UUID())
            guard selection.accepts(generation, taskID: id) else { return }
            switch result {
            case .taskDetail(let detail):
                guard selection.accepts(generation, detail: detail, minimumSeq: taskReadFloors[id] ?? 0) else { return }
                self.detail = detail
            case .error(let error): self.error = error.message
            default: self.error = "Не удалось получить детали задачи."
            }
        } catch {
            guard selection.accepts(generation, taskID: id) else { return }
            self.error = error.localizedDescription
        }
    }
    func prepareCreation() { editorError = nil; createdTaskID = nil }
    func create(_ draft: DemoTaskDraft, in projectID: ProjectID) async {
        guard draft.canSubmit, projection?.projects[projectID] != nil else { return }
        let commandID = UUID()
        guard creation.begin(commandID: commandID, projectID: projectID) else { return }
        editorError = nil
        do {
            let result = try await client.send(.createTask(projectId: projectID, title: draft.title, body: draft.body), commandId: commandID)
            if case .error(let error) = result {
                guard creation.commandID == commandID else { return }
                creation.fail(commandID); editorError = error.message
            }
            // A task ID in the receipt is not a card. Selection waits for correlated taskCreated.
        } catch {
            guard creation.commandID == commandID else { return }
            creation.fail(commandID); editorError = error.localizedDescription
        }
    }
    @discardableResult func send(_ command: Command, taskID: TaskID, editor: Bool = false) async -> Bool {
        guard let board = projection, board.tasks[taskID] != nil, !board.isSent(taskID) else { return false }
        let commandID = UUID()
        projection?.markSent(commandId: commandID, taskId: taskID, at: Date())
        do {
            if case .error(let commandError) = try await client.send(command, commandId: commandID) {
                projection?.noteCommandError(commandID)
                if editor { editorError = commandError.message } else { error = commandError.message }
                return false
            }
            return true
        } catch {
            projection?.noteCommandError(commandID)
            if editor { editorError = error.localizedDescription } else { self.error = error.localizedDescription }
            return false
        }
    }
    var runningCount: Int { projection?.tasks.values.filter { $0.state == .running || $0.state == .gating }.count ?? 0 }
    var waitingCount: Int { projection?.tasks.values.filter { $0.state.status == .waitingHuman }.count ?? 0 }
    func matches(_ id: TaskID) -> Bool {
        guard let card = projection?.tasks[id] else { return false }
        let acceptsFilter = filter == .all || (filter == .waiting && card.state.status == .waitingHuman) || (filter == .incidents && card.state == .waitingHuman(.incident))
        return acceptsFilter && (query.isEmpty || card.title.localizedCaseInsensitiveContains(query) || card.id.rawValue.localizedCaseInsensitiveContains(query))
    }
    func mascot(_ id: ProjectID) -> MascotPick {
        let projects = boardSet.addedOrder.compactMap { id -> (id: String, seed: String)? in
            guard let project = projection?.projects[id] else { return nil }
            return (id.rawValue, project.mascotSeed)
        }
        return MascotKit.resolveBoard(projects)[id.rawValue] ?? MascotKit.pick(seed: projection?.projects[id]?.mascotSeed ?? id.rawValue)
    }
    func projectStatus(_ id: ProjectID) -> String {
        if (projection?.projects[id]?.openIncidentCount ?? 0) > 0 { return "incident" }
        if projection?.tasks.values.contains(where: { $0.projectId == id && $0.state.status == .waitingHuman }) == true { return "waiting" }
        if projection?.ephemeral.schedulerFlags.contains(.projectPaused(id)) == true { return "paused" }
        return projection?.tasks.values.contains(where: { $0.projectId == id && $0.state == .running }) == true ? "running" : "queued"
    }
    func projectCaption(_ id: ProjectID) -> String {
        guard let project = projection?.projects[id] else { return "Нет данных" }
        if project.availability == .missing { return "Папка недоступна" }
        if projection?.pipelines[id]?.isValid == false { return "Пайплайн некорректен" }
        if projection?.ephemeral.schedulerFlags.contains(.projectPaused(id)) == true { return "Новые запуски на паузе" }
        let waiting = projection?.tasks.values.filter { $0.projectId == id && $0.state.status == .waitingHuman }.count ?? 0
        if waiting > 0 { return "Ждут человека · \(waiting)" }
        if projection?.tasks.values.contains(where: { $0.projectId == id && $0.state == .running }) == true { return "В работе" }
        let queued = projection?.tasks.values.filter { $0.projectId == id && $0.state.status == .queued }.count ?? 0
        return queued > 0 ? "В очереди · \(queued)" : "Очередь пуста"
    }
    func beginCreation(_ projectID: ProjectID? = nil) {
        guard let id = projectID ?? selectedProjectID, creation.commandID == nil else { return }
        selectedProjectID = id; prepareCreation(); sheet = .create(id)
    }
    func hide(_ id: ProjectID) { boardSet.hide(id); visibleIDs = boardSet.visibleProjectIds }
    func show(_ id: ProjectID) { boardSet.show(id); visibleIDs = boardSet.visibleProjectIds }
}
