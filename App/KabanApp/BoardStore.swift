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
    let session: BoardSession
    let environment: RunnerEnvironmentStore
    let projects: ProjectLifecycleStore
    let folderAccess: ProjectFolderAccess
    let usesFixture: Bool
    let dataSource: String
    let dataSourceDetail: String
    private var subscription: Task<Void, Never>?
    var capabilities: DaemonCapabilities? { session.capabilities }
    var commandJournal: ClientCommandJournal? { session.journal }
    private var boardSet: BoardSetStore { session.boardSet }
    var screen: BoardScreen = .board
    var filter: BoardFilter = .all
    var query = ""
    var searchRequest = 0
    var sheet: TaskSheetRoute?
    var projectSheet: ProjectSheetRoute?
    var qaLayoutRevision = 0
    var projection: BoardProjection? { get { session.projection } set { session.projection = newValue } }
    var visibleIDs: [ProjectID] { session.visibleIDs }
    var selectedProjectID: ProjectID? { get { session.selectedProjectID } set { session.selectedProjectID = newValue } }
    var selectedID: TaskID? { session.selectedID }
    var detail: TaskDetail? { session.detail }
    var error: String? { get { session.error } set { session.error = newValue } }
    var editorError: String? { get { session.editorError } set { session.editorError = newValue } }
    var creation: TaskCreationPending { session.creation }
    var createdTaskID: TaskID? { session.createdTaskID }
    var connectionState: DaemonConnectionState { get { session.connectionState } set { session.connectionState = newValue } }
    var canSend: Bool { session.canSend }
    func can(_ name: CommandName) -> Bool { session.can(name) }
    func unavailableReason(_ name: CommandName) -> String {
        if can(name) { return "" }
        return canSend ? "Подключённая служба не поддерживает это действие. Обновите службу Kaban." : "Действие будет доступно после подключения и синхронизации."
    }
    init(client: any KabanClient, storage: any KeyValueStoring = DefaultsStorage(), dataSource: String = "Служба Kaban · на этом Маке", dataSourceDetail: String = "", commandStorageKey: String = "client.commands.installed", fixture: Bool = false) {
        self.client = client; usesFixture = fixture || client is MockKabanClient
        self.dataSource = usesFixture ? "Демонстрация · данные в памяти" : dataSource
        self.dataSourceDetail = dataSourceDetail
        let sourceKey = usesFixture ? "client.commands.fixture" : commandStorageKey
        let session = BoardSession(client: client, storage: storage, key: sourceKey)
        self.session = session
        projects = ProjectLifecycleStore(client: client, session: session, storage: storage, key: sourceKey + ".projectDrafts")
        folderAccess = ProjectFolderAccess(storage: storage, key: sourceKey + ".folderBookmarks")
        environment = RunnerEnvironmentStore(client: client, session: session)
    }
    isolated deinit { session.stop(); subscription?.cancel() }
    func connect() async {
        guard subscription == nil else { return }
        let session = session
        subscription = Task { await session.run() }
    }
    func stop() { session.stop(); subscription?.cancel(); subscription = nil }
    func retry() {
        let previous = subscription, session = session
        previous?.cancel()
        subscription = Task { await previous?.value; await session.run() }
    }
    func select(_ id: TaskID?) async { await session.select(id) }
    func prepareCreation() { session.prepareCreation() }
    func create(_ draft: DemoTaskDraft, in projectID: ProjectID) async {
        let command = Command.createTask(projectId: projectID, title: draft.title, body: draft.body)
        guard draft.canSubmit, projection?.projects[projectID] != nil, session.can(command) else { return }
        do { try session.drafts?.save(.init(key: .create(projectID), draft: draft)) }
        catch { editorError = "Не удалось сохранить черновик. \(error.localizedDescription)"; return }
        _ = await session.send(command, editor: true)
    }
    @discardableResult func send(_ command: Command, taskID: TaskID, editor: Bool = false) async -> Bool {
        guard projection?.tasks[taskID] != nil else { return false }
        return await session.send(command, editor: editor)
    }
    func pendingLabel(_ scope: CommandScope) -> String? {
        guard let phase = session.pending(in: scope)?.phase else { return nil }
        switch phase {
        case .sending: return "Отправляем…"
        case .deliveryUncertain: return "Проверяем отправку…"
        case .awaitingEvent: return "Ждём подтверждения…"
        case .awaitingEffect: return "Восстанавливаем WIP…"
        default: return nil
        }
    }
    var connectionLabel: String? {
        switch connectionState {
        case .connecting: "Подключаемся к Kaban…"
        case .synchronizing: "Сверяем доску и сохранённые отправки…"
        case .connected: nil
        case .reconnecting: "Связь прервана. Восстанавливаем соединение…"
        case .disconnected(let error): error.message
        }
    }
    func readLog(runId: RunID, fromOffset: Int64, limit: Int = DaemonWire.maxPageSize) async throws -> LogPage {
        guard capabilities?.supportsOperation("readLog") == true else { throw CommandError(code: CommandError.unsupportedOperationCode, message: "Источник данных не поддерживает чтение логов.") }
        return try await client.readLog(runId: runId, fromOffset: fromOffset, limit: limit)
    }
    func tailLog(runId: RunID, fromOffset: Int64) -> AsyncThrowingStream<LogBatch, Error> {
        guard capabilities?.supportsOperation("readLog") == true else {
            return AsyncThrowingStream { $0.finish(throwing: CommandError(code: CommandError.unsupportedOperationCode, message: "Источник данных не поддерживает чтение логов.")) }
        }
        return client.tailLog(runId: runId, fromOffset: fromOffset)
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
        let missingPipeline = projection?.ephemeral.schedulerFlags.contains { flag in
            if case .projectUnavailable(let projectID, .noPipeline, _) = flag { return projectID == id }; return false
        } == true || projection?.pipelines[id]?.issues.contains { $0.code == "pipeline_missing" } == true
        if missingPipeline { return "Пайплайн не настроен" }
        if projection?.pipelines[id]?.isValid == false { return "Пайплайн некорректен" }
        if projection?.ephemeral.schedulerFlags.contains(.projectPaused(id)) == true { return "Новые запуски на паузе" }
        let waiting = projection?.tasks.values.filter { $0.projectId == id && $0.state.status == .waitingHuman }.count ?? 0
        if waiting > 0 { return "Ждут человека · \(waiting)" }
        if projection?.tasks.values.contains(where: { $0.projectId == id && $0.state == .running }) == true { return "В работе" }
        let queued = projection?.tasks.values.filter { $0.projectId == id && $0.state.status == .queued }.count ?? 0
        return queued > 0 ? "В очереди · \(queued)" : "Очередь пуста"
    }
    func beginProjectFlow(_ route: ProjectSheetRoute) {
        sheet = nil; error = nil; editorError = nil
        projects.open(route.operation); projectSheet = route
    }
    func beginCreation(_ projectID: ProjectID? = nil) {
        guard can(.createTask), let id = projectID ?? selectedProjectID else { return }
        selectedProjectID = id; prepareCreation(); sheet = .create(id)
    }
    func hide(_ id: ProjectID) { session.hide(id) }
    func show(_ id: ProjectID) { session.show(id) }
}
