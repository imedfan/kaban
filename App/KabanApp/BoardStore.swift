import AppKit
import Foundation
import Observation
import KabanProtocol
import KabanBoardCore

final class DefaultsStorage: KeyValueStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    init(suiteName: String) { defaults = UserDefaults(suiteName: suiteName) ?? .standard }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }
}

@MainActor @Observable final class BoardStore {
    private let client: any KabanClient
    let runLog: RunLogStore
    let session: BoardSession
    let humanAnswers: HumanAnswerStore
    let incidents: IncidentsStore
    let incidentDecisions: IncidentDecisionStore
    let humanReview: HumanReviewStore
    let suspiciousFiles: SuspiciousFilesStore
    var suspiciousReturnRoute: SuspiciousReturnRoute?
    var fileOpeningError: String?
    var detailScrollTarget: TaskDetailAnchor?
    let gitPermissions: GitPermissionsStore
    let environment: RunnerEnvironmentStore
    let models: ModelSettingsStore
    let macSettings: MacSettingsStore
    var activeMacSettings: MacSettingsStore? {
        screen == .quota && sheet == nil && controlSheet == nil && projectSheet == nil && logRunRoute == nil
            && reviewRoute == nil && modelOverrideRoute == nil && gitPermissions.preview == nil
            && suspiciousReturnRoute == nil && overlapRoute == nil
            && materialTextRoute == nil && wipRestoreRoute == nil ? macSettings : nil
    }
    var modelOverrideRoute: TaskModelOverrideStore?
    let projects: ProjectLifecycleStore
    let folderAccess: ProjectFolderAccess
    private var pipelineEditors: [ProjectID: PipelineEditorStore] = [:]
    private var projectSettings: [ProjectID: ProjectSettingsStore] = [:]
    private var projectMCPStores: [ProjectID: ProjectMCPStore] = [:]
    var mcpProjectID: ProjectID?
    func mcpSettings(for id: ProjectID) -> ProjectMCPStore {
        if let settings = projectMCPStores[id] { return settings }
        let settings = ProjectMCPStore(projectID: id, client: client, session: session)
        projectMCPStores[id] = settings
        return settings
    }
    var activeProjectSettings: ProjectSettingsStore? {
        guard case .project(let id) = screen, mcpProjectID == nil, editingPipelineProject == nil, mascotProjectID == nil, projectSheet == nil,
              let settings = projectSettings[id], settings.section != nil else { return nil }
        return settings
    }
    func settings(for id: ProjectID) -> ProjectSettingsStore {
        if let settings = projectSettings[id] { return settings }
        let settings = ProjectSettingsStore(projectID: id, session: session)
        projectSettings[id] = settings
        return settings
    }
    var editingPipelineProject: ProjectID?
    var activePipelineEditor: PipelineEditorStore? {
        guard case .project(let id) = screen, mcpProjectID == nil, editingPipelineProject == id else { return nil }
        return pipelineEditors[id]
    }
    func pipelineEditor(for id: ProjectID) -> PipelineEditorStore {
        if let editor = pipelineEditors[id] { return editor }
        let editor = PipelineEditorStore(projectID: id, client: client, session: session)
        pipelineEditors[id] = editor
        return editor
    }
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
    var focusRequest = 0
    var compactBoard = false
    var mascotProjectID: ProjectID?
    private var runFacts: [TaskID: (card: TaskCard, generation: UUID, run: RunSummary?)] = [:]
    var taskDropNotice: String?
    var controlSheet: TaskControlRoute?
    var sheet: TaskSheetRoute?
    var projectSheet: ProjectSheetRoute?
    var qaLayoutRevision = 0
    var materialTextRoute: MaterialTextRoute?
    var logSearchRequest = 0
    var wipRestoreRoute: WIPRestoreRoute?
    var logRunRoute: RunSummary?
    var reviewRoute: HumanReviewRoute?
    var overlapRoute: OverlapRoute?
    var cloneOpeningError: String?
    var openingClone = false
    var requestedPipelineSection: String?
    var showPipelineIssues = false
    func openIncidentPolicy(_ project: ProjectID) {
        guard projection?.projects[project] != nil else { return }
        mcpProjectID = nil; requestedPipelineSection = "__git"; showPipelineIssues = true
        selectedProjectID = project; screen = .project(project)
    }
    var detailTab = "Описание"
    private var projectRechecks: [ProjectID: CommandID] = [:]
    func mergeQueue(_ project: ProjectID) -> [TaskCard] {
        MergePresentation.queue(project: project, tasks: projection.map { Array($0.tasks.values) } ?? [], pipeline: projection?.pipelines[project])
    }
    func recheckRecord(_ project: ProjectID) -> ClientCommandJournal.Record? {
        _ = session.pendingRecords
        guard let id = projectRechecks[project] else { return nil }
        return session.journal?.records.first { $0.envelope.commandId == id }
    }
    func canRecheck(_ project: ProjectID) -> Bool {
        session.can(.recheck(scope: .project(projectId: project))) && session.pending(in: .project(project)) == nil
            && capabilities?.commands.first { $0.name == CommandName.recheck.rawValue }?.scopes?.contains("project") == true
    }
    func recheckProject(_ project: ProjectID) async {
        guard canRecheck(project) else { return }
        let envelope = CommandEnvelope(command: .recheck(scope: .project(projectId: project)))
        projectRechecks[project] = envelope.commandId
        _ = await session.send(envelope)
    }
    func openRelatedTask(_ id: TaskID) async {
        guard let card = projection?.tasks[id] else { return }
        overlapRoute = nil; focusProject(card.projectId); filter = .all; query = ""
        await select(id)
    }
    var projection: BoardProjection? { get { session.projection } set { session.projection = newValue } }
    var visibleIDs: [ProjectID] { session.visibleIDs }
    var selectedProjectID: ProjectID? { get { session.selectedProjectID } set { session.selectedProjectID = newValue } }
    var selectedID: TaskID? { session.selectedID }
    var detail: TaskDetail? {
        guard let detail = session.detail, detail.task.id == selectedID else { return nil }
        return detail
    }
    var error: String? { get { session.error } set { session.error = newValue } }
    var editorError: String? { get { session.editorError } set { session.editorError = newValue } }
    var creation: TaskCreationPending { session.creation }
    var createdTaskID: TaskID? { session.createdTaskID }
    var connectionState: DaemonConnectionState { get { session.connectionState } set { session.connectionState = newValue } }
    var canSend: Bool { session.canSend }
    var canAnswerSelected: Bool {
        guard let id = selectedID, screen == .board, sheet == nil, controlSheet == nil,
              projectSheet == nil, logRunRoute == nil, materialTextRoute == nil, wipRestoreRoute == nil, reviewRoute == nil, overlapRoute == nil, suspiciousReturnRoute == nil, gitPermissions.preview == nil else { return false }
        return humanAnswers.canSubmit(id)
    }
    var selectedIncidentID: IncidentID? {
        if let id = incidents.selectedID, incidents.selected?.taskId == selectedID { return id }
        return selectedID.flatMap { id in incidents.forTask(id).first(where: { $0.resolvedAt == nil })?.id }
    }
    var canResolveIncident: Bool {
        guard screen == .board || screen == .incidents, sheet == nil, controlSheet == nil, projectSheet == nil,
              logRunRoute == nil, modelOverrideRoute == nil, materialTextRoute == nil, wipRestoreRoute == nil,
              reviewRoute == nil, overlapRoute == nil, suspiciousReturnRoute == nil, gitPermissions.preview == nil, let id = selectedIncidentID else { return false }
        return incidentDecisions.canSubmit(id)
    }
    func resolveIncident() { if canResolveIncident, let id = selectedIncidentID { Task { await incidentDecisions.submit(id) } } }
    func answerSelected() { if canAnswerSelected, let id = selectedID { Task { await humanAnswers.submit(id) } } }
    var canApproveSelected: Bool {
        guard let id = selectedID, screen == .board, sheet == nil, controlSheet == nil, projectSheet == nil,
              logRunRoute == nil, materialTextRoute == nil, wipRestoreRoute == nil, reviewRoute == nil, overlapRoute == nil, suspiciousReturnRoute == nil, gitPermissions.preview == nil else { return false }
        return humanReview.canSubmit(.approve, for: id)
    }
    func approveSelected() { if canApproveSelected, let id = selectedID { Task { await humanReview.submit(.approve, for: id) } } }
    func beginReview(_ decision: HumanReviewDecision, task id: TaskID) {
        guard humanReview.draft(for: id) != nil, selectedID == id else { return }
        reviewRoute = .init(taskID: id, decision: decision)
    }
    func openPipelineIssues(_ project: ProjectID) {
        reviewRoute = nil; showPipelineIssues = true; selectedProjectID = project; screen = .project(project)
    }
    @discardableResult func openClone(_ path: String?) async -> Bool {
        let task = selectedID
        guard !openingClone else { return false }
        cloneOpeningError = nil
        var directory: ObjCBool = false
        guard let path, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            cloneOpeningError = "Папка клона недоступна. Обновите детали и проверьте путь."; return false
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") else {
            cloneOpeningError = "Cursor не найден. Установите редактор или скопируйте путь клона."; return false
        }
        openingClone = true
        let error: String? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: .init()) { _, failure in
                continuation.resume(returning: failure?.localizedDescription)
            }
        }
        openingClone = false
        if selectedID == task { cloneOpeningError = error }
        return error == nil
    }
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
        let incidents = IncidentsStore(client: client, session: session)
        self.incidents = incidents
        incidentDecisions = IncidentDecisionStore(session: session, incidents: incidents, storage: storage, key: sourceKey + ".incidentDecisions")
        humanAnswers = HumanAnswerStore(session: session, storage: storage, key: sourceKey + ".humanAnswers")
        suspiciousFiles = SuspiciousFilesStore(session: session, storage: storage, key: sourceKey + ".suspiciousFiles")
        humanReview = HumanReviewStore(session: session, storage: storage, key: sourceKey + ".humanReview")
        gitPermissions = GitPermissionsStore(client: client, session: session)
        runLog = RunLogStore(client: client)
        projects = ProjectLifecycleStore(client: client, session: session, storage: storage, key: sourceKey + ".projectDrafts")
        folderAccess = ProjectFolderAccess(storage: storage, key: sourceKey + ".folderBookmarks")
        environment = RunnerEnvironmentStore(client: client, session: session)
        models = ModelSettingsStore(client: client, session: session)
        macSettings = MacSettingsStore(session: session, storage: storage, key: sourceKey + ".macSettings")
    }
    isolated deinit { incidents.stop(); runLog.close(); session.stop(); subscription?.cancel() }
    func connect() async {
        guard subscription == nil else { return }
        let session = session
        subscription = Task { await session.run() }
    }
    func stop() { incidents.stop(); runLog.close(); session.stop(); subscription?.cancel(); subscription = nil }
    func retry() {
        let previous = subscription, session = session
        previous?.cancel()
        subscription = Task { await previous?.value; await session.run() }
    }
    func select(_ id: TaskID?) async {
        if id == nil, screen == .incidents { incidents.selectedID = nil }
        if selectedID != id { modelOverrideRoute = nil; logRunRoute = nil; wipRestoreRoute = nil; reviewRoute = nil; suspiciousReturnRoute = nil; detailScrollTarget = nil; fileOpeningError = nil; cloneOpeningError = nil; runLog.close() }
        await session.select(id)
    }
    func find() {
        // The foremost native sheet owns text search, including a separately
        // loaded source record. Do not steal focus into its covered log/board.
        if var sheet = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && $0.isVisible })?.attachedSheet {
            while let next = sheet.attachedSheet { sheet = next }
            func readers(_ view: NSView) -> [NSTextView] {
                if let text = view as? NSTextView, !text.isFieldEditor, text.usesFindBar { return [text] }
                return view.subviews.flatMap(readers)
            }
            if let text = sheet.contentView.flatMap({ readers($0).first }) {
                sheet.makeFirstResponder(text)
                let action = NSMenuItem(); action.tag = NSTextFinder.Action.showFindInterface.rawValue
                text.performTextFinderAction(action); return
            }
        }
        if logRunRoute != nil { logSearchRequest += 1 }
        else { screen = .board; searchRequest += 1 }
    }
    func history(for id: TaskID) -> [RunSummary] {
        guard selectedID == id else { return [] }
        return session.runHistory ?? detail?.runs ?? []
    }
    func beginWIPRestore(_ run: RunSummary) {
        guard let card = projection?.tasks[run.taskId], selectedID == card.id else { return }
        let route = WIPRestoreRoute(store: self, card: card, run: run)
        guard route.request.isAvailable else { return }
        editorError = nil; wipRestoreRoute = route
    }
    func restoreRecord(for id: TaskID) -> ClientCommandJournal.Record? {
        _ = session.pendingRecords
        return commandJournal?.records.last {
            if case .restoreWIP(let task, _, _) = $0.envelope.command { return task == id }
            return false
        }
    }
    func prepareCreation() { session.prepareCreation() }
    func create(_ draft: DemoTaskDraft, in projectID: ProjectID) async {
        _ = await create(draft, body: draft.body, in: projectID)
    }
    @discardableResult func create(_ draft: DemoTaskDraft, body: String, in projectID: ProjectID) async -> Bool {
        let command = Command.createTask(projectId: projectID, title: draft.title, body: body)
        guard draft.canSubmit, projection?.projects[projectID] != nil, session.can(command) else { return false }
        do { try session.drafts?.save(.init(key: .create(projectID), draft: draft, exactBody: body)) }
        catch { editorError = "Не удалось сохранить черновик. \(error.localizedDescription)"; return false }
        return await session.send(command, editor: true)
    }
    var visibleMatchCount: Int {
        projection?.tasks.values.filter { card in
            guard visibleIDs.contains(card.projectId), matches(card.id) else { return false }
            let hidden = projection?.pipelines[card.projectId]?.stages.first { $0.id == card.stageId }?.display.hidden == true
            return filter == .hiddenStages ? hidden : !hidden
        }.count ?? 0
    }
    var hasTaskFilter: Bool { !query.isEmpty || filter == .waiting || filter == .incidents }
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
    var reservationCount: Int { projection?.tasks.values.filter { $0.state == .running }.count ?? 0 }
    func currentRun(for card: TaskCard) -> RunSummary? { runFacts[card.id].flatMap { $0.card == card && $0.generation == session.sessionGeneration ? $0.run : nil } }
    func progress(for card: TaskCard) -> RunProgress? {
        CardPresentation.progress(card: card, currentRun: currentRun(for: card), reports: projection?.ephemeral.runProgress ?? [:])
    }
    func readRunFacts(for card: TaskCard) async {
        guard card.state == .running || card.state == .waitingHuman(.modelSubstituted), can(.getTaskDetail) else { return }
        if let facts = runFacts[card.id], facts.card == card && facts.generation == session.sessionGeneration { return }
        let generation = session.sessionGeneration
        do {
            let reply = try await client.send(.init(command: .getTaskDetail(taskId: card.id)))
            guard case .taskDetail(let detail) = reply.result else { return }
            guard !Task.isCancelled, session.sessionGeneration == generation,
                  projection?.tasks[card.id] == card, detail.task == card else { return }
            let matching = detail.runs.filter { run in
                run.taskId == card.id && run.stageId == card.stageId &&
                (card.state != .running || (run.endedAt == nil && (run.status == .starting || run.status == .running)))
            }
            let run = matching.max { $0.number < $1.number }
            runFacts[card.id] = (card, generation, run)
        } catch { /* Optional presentation facts stay unknown; task commands are unaffected. */ }
    }
    var hiddenStageCount: Int {
        projection?.tasks.values.filter { card in
            projection?.pipelines[card.projectId]?.stages.first(where: { $0.id == card.stageId })?.display.hidden == true
        }.count ?? 0
    }
    var waitingCount: Int { projection?.tasks.values.filter { $0.state.status == .waitingHuman }.count ?? 0 }
    func matches(_ id: TaskID) -> Bool {
        guard let card = projection?.tasks[id] else { return false }
        let acceptsFilter = filter == .all || (filter == .waiting && card.state.status == .waitingHuman) || (filter == .incidents && card.state == .waitingHuman(.incident)) || (filter == .hiddenStages && projection?.pipelines[card.projectId]?.stages.first(where: { $0.id == card.stageId })?.display.hidden == true)
        return acceptsFilter && (query.isEmpty || card.title.localizedCaseInsensitiveContains(query) || card.id.rawValue.localizedCaseInsensitiveContains(query))
    }
    func mascot(_ id: ProjectID) -> MascotPick {
        let projects = boardSet.addedOrder.compactMap { id -> (id: String, seed: String)? in
            guard let project = projection?.projects[id] else { return nil }
            return (id.rawValue, project.mascotSeed)
        }
        return MascotKit.resolveBoard(projects)[id.rawValue] ?? MascotKit.pick(seed: projection?.projects[id]?.mascotSeed ?? id.rawValue)
    }
    func completionTrigger(_ id: ProjectID) -> Int64 {
        projection?.feed.last { item in
            guard item.projectId == id, case .taskTransitioned(let transition) = item.event else { return false }
            return transition.to == .done
        }?.seq ?? 0
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
        guard controlSheet == nil else { return }
        sheet = nil; error = nil; editorError = nil
        projects.open(route.operation); projectSheet = route
    }
    func beginCreation(_ projectID: ProjectID? = nil) {
        guard controlSheet == nil, projectSheet == nil, reviewRoute == nil, overlapRoute == nil, suspiciousReturnRoute == nil, gitPermissions.preview == nil, can(.createTask), let id = projectID ?? selectedProjectID else { return }
        selectedProjectID = id; prepareCreation(); sheet = .create(id)
    }
    func hide(_ id: ProjectID) { session.hide(id) }
    func show(_ id: ProjectID) { session.show(id) }
    func focusProject(_ id: ProjectID) {
        guard projection?.projects[id] != nil else { return }
        selectedProjectID = id; screen = .board
        if !visibleIDs.contains(id) { show(id) }
        focusRequest += 1
    }
    func focusProject(at index: Int) {
        guard visibleIDs.indices.contains(index) else { return }; focusProject(visibleIDs[index])
    }
    func moveProject(_ id: ProjectID, by delta: Int) {
        guard let index = visibleIDs.firstIndex(of: id), visibleIDs.indices.contains(index + delta) else { return }
        session.move(id, to: index + delta); focusProject(id)
    }
    @discardableResult func dropProject(_ values: [String], before target: ProjectID?) -> Bool {
        guard values.count == 1, values[0].hasPrefix("kaban-project:"),
              !values[0].dropFirst("kaban-project:".count).isEmpty else { return false }
        let id = ProjectID(rawValue: String(values[0].dropFirst("kaban-project:".count)))
        guard projection?.projects[id] != nil, id != target else { return false }
        let remaining = visibleIDs.filter { $0 != id }
        let index = target.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
        if visibleIDs.contains(id) { session.move(id, to: index) } else { session.show(id, at: index) }
        focusProject(id); return true
    }
    func setMascot(_ id: ProjectID, index: Int, texture: EdgeTexture) async {
        guard projection?.projects[id] != nil,
              let seed = MascotKit.seed(for: id.rawValue, mascotIndex: index, texture: texture) else { return }
        _ = await session.send(.setMascot(projectId: id, seed: seed))
    }

}
