import Foundation
import KabanProtocol

/// Transport boundary shared by the fixture client and the daemon adapter.
/// Commands return acknowledgements; only snapshots and events change the board.
@MainActor public protocol KabanClient: AnyObject {
    func getSnapshot() async throws -> Snapshot
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error>
    func events() -> AsyncStream<EventEnvelope>
    func send(_ command: Command, commandId: CommandID) async throws -> CommandResult
}

public enum KabanClientUpdate: Sendable {
    case event(EventEnvelope)
    case replacement(SnapshotReplacement)
    case connection(DaemonConnectionState)
    case ephemeral(EphemeralEnvelope)
}
extension KabanClient {
    public func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> {
        let stream = events()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(DaemonWire.maxPageSize * 2)) { continuation in
            let task = Task { @MainActor in
                continuation.yield(.connection(.connected))
                for await event in stream {
                    if case .dropped = continuation.yield(.event(event)) {
                        continuation.finish(throwing: CommandError(code: "buffer_overflow", message: "Update stream overflow")); return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@MainActor public final class MockKabanClient: KabanClient {
    private var snapshot: Snapshot
    private var continuations: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]
    private var journal: [EventEnvelope] = []
    private var bodies: [TaskID: String] = [:]
    private var receipts: [CommandID: (Command, CommandResult)] = [:]
    private var notes: [TaskID: [FeedItem]] = [:]


    public init(snapshot: Snapshot = MockKabanClient.fixture(), taskBodies: [TaskID: String] = [:]) { self.snapshot = snapshot; self.bodies = taskBodies }
    public func getSnapshot() async throws -> Snapshot { snapshot }
    public func events() -> AsyncStream<EventEnvelope> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }
    public func send(_ command: Command, commandId: CommandID) async throws -> CommandResult {
        if let receipt = receipts[commandId] {
            guard receipt.0 == command else { return .error(CommandError(code: "command_id_conflict", message: "Этот идентификатор уже использован для другого действия.")) }
            return receipt.1
        }
        let result = execute(command, commandId: commandId)
        receipts[commandId] = (command, result)
        return result
    }
    private func execute(_ command: Command, commandId: CommandID) -> CommandResult {
        switch command {
        case .getTaskDetail(let id):
            guard let task = snapshot.tasks.first(where: { $0.id == id }) else { return missingTask() }
            var feed = journal.compactMap { envelope -> FeedItem? in
                guard case .taskUpdated(let updated) = envelope.event, updated.id == id else { return nil }
                return FeedItem(id: String(envelope.seq), at: envelope.at, kind: "transition", text: CardPresentation(state: updated.state).label)
            }
            feed += notes[id] ?? []
            feed.sort { $0.at < $1.at }
            return .taskDetail(TaskDetail(seq: snapshot.seq, task: task, feed: feed, runs: [], suspiciousFiles: task.suspiciousFiles, acceptedFiles: accepted[id] ?? [], body: bodies[id]))
        case .createTask(let projectID, let title, let body):
            guard snapshot.projects.contains(where: { $0.id == projectID }) else { return .error(CommandError(code: "project_not_found", message: "Проект не найден.")) }
            guard let pipeline = snapshot.pipelines.first(where: { $0.projectId == projectID }),
                  let queue = pipeline.stages.first(where: { $0.kind == .queue }) else { return invalidState() }
            let draft = DemoTaskDraft(title: title, body: body)
            guard draft.canSubmit, !body.contains("\0") else { return .error(CommandError(code: "invalid_request", message: "Укажите заголовок задачи; поля не должны содержать NUL.")) }
            let id = TaskID(rawValue: UUID().uuidString)
            let task = TaskCard(id: id, projectId: projectID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), stageId: queue.id,
                                state: .queued(nil), hasAcceptanceCriteria: draft.hasAcceptanceCriteria, updatedAt: Date())
            snapshot.tasks.append(task)
            bodies[id] = body
            emit(.taskCreated(task), projectID: projectID, commandID: commandId)
            return .taskCreated(id)
        case .editTask(let id, let title, let body):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard TaskActions.canEdit(snapshot.tasks[index]) else { return invalidState() }
            guard title != nil || body != nil else { return .error(CommandError(code: "invalid_request", message: "Нет изменений.")) }
            if let body, body.contains("\0") { return .error(CommandError(code: "invalid_request", message: "Описание содержит NUL.")) }
            var draft = DemoTaskDraft(title: snapshot.tasks[index].title, body: bodies[id] ?? "")
            if let title {
                draft.title = title
                guard draft.canSubmit else { return .error(CommandError(code: "invalid_request", message: "Укажите заголовок задачи.")) }
                snapshot.tasks[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let body {
                guard !body.contains("\0") else { return .error(CommandError(code: "invalid_request", message: "Описание содержит NUL.")) }
                draft = DemoTaskDraft(title: snapshot.tasks[index].title, body: body)
                snapshot.tasks[index].hasAcceptanceCriteria = draft.hasAcceptanceCriteria
                bodies[id] = body
            }
            snapshot.tasks[index].updatedAt = Date()
            emit(.taskEdited(snapshot.tasks[index]), projectID: snapshot.tasks[index].projectId, commandID: commandId)
            emit(.taskUpdated(snapshot.tasks[index]), projectID: snapshot.tasks[index].projectId, commandID: commandId)
            return .ok
        case .moveTask(let id, let targetID):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            let task = snapshot.tasks[index]
            guard snapshot.projects.first(where: { $0.id == task.projectId })?.availability == .available,
                  let pipeline = snapshot.pipelines.first(where: { $0.projectId == task.projectId }), pipeline.isValid,
                  let target = pipeline.stages.first(where: { $0.id == targetID }) else { return invalidState() }
            guard TaskActions.moveDecision(card: task, target: target, pipeline: pipeline).isAllowed else { return invalidState() }
            acceptDemoFiles(index, commandID: commandId)
            return update(index, state: .queued(nil), commandId: commandId, stageID: targetID)
        case .cancelTask(let id, let keepBranch):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard TaskActions.canCancel(snapshot.tasks[index]) else { return invalidState() }
            acceptDemoFiles(index, commandID: commandId)
            if keepBranch, snapshot.tasks[index].branch != nil {
                notes[id, default: []].append(FeedItem(id: UUID().uuidString, at: Date(), kind: "summary", text: "Демо: выбрано сохранение ветки при отмене."))
            } else { snapshot.tasks[index].branch = nil }
            return update(index, state: .cancelled, commandId: commandId)
        case .pauseTask(let id):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard snapshot.tasks[index].state == .running else { return invalidState() }
            return update(index, state: .paused, commandId: commandId)
        case .resumeTask(let id):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard snapshot.tasks[index].state == .paused else { return invalidState() }
            return update(index, state: .queued(nil), commandId: commandId)
        default:
            return .error(CommandError(code: "unknown_command", message: "Это действие пока недоступно в демонстрационном клиенте."))
        }
    }
    private func missingTask() -> CommandResult { .error(CommandError(code: "task_not_found", message: "Задача не найдена.")) }
    private func invalidState() -> CommandResult { .error(CommandError(code: "invalid_state", message: "Состояние задачи изменилось.")) }
    private func update(_ index: Int, state: TaskState, commandId: CommandID, stageID: StageID? = nil) -> CommandResult {
        let previous = snapshot.tasks[index]
        snapshot.tasks[index].state = state
        if let stageID { snapshot.tasks[index].stageId = stageID }
        snapshot.tasks[index].updatedAt = Date()
        let task = snapshot.tasks[index]
        emit(.taskUpdated(task), projectID: task.projectId, commandID: commandId)
        for loadIndex in snapshot.stageLoad.indices where snapshot.stageLoad[loadIndex].projectId == task.projectId {
            let load = snapshot.stageLoad[loadIndex]
            guard let kind = snapshot.pipelines.first(where: { $0.projectId == task.projectId })?.stages.first(where: { $0.id == load.stageId })?.kind else { continue }
            let before = previous.stageId == load.stageId && previous.state.status.occupiesWIP(in: kind) ? 1 : 0
            let after = task.stageId == load.stageId && state.status.occupiesWIP(in: kind) ? 1 : 0
            if before != after {
                snapshot.stageLoad[loadIndex].wipUsed = max(0, load.wipUsed + after - before)
                emit(.stageLoadChanged(snapshot.stageLoad[loadIndex]), projectID: task.projectId, commandID: commandId)
            }
        }
        return .ok
    }
    private func emit(_ event: JournalEvent, projectID: ProjectID, commandID: CommandID) {
        snapshot.seq += 1
        publish(EventEnvelope(seq: snapshot.seq, at: Date(), projectId: projectID, commandId: commandID, event: event))
    }
    private func acceptDemoFiles(_ index: Int, commandID: CommandID) {
        let task = snapshot.tasks[index]
        guard !task.suspiciousFiles.isEmpty else { return }
        accepted[task.id, default: []] += task.suspiciousFiles.map { AcceptedFile(path: $0.path, blob: $0.blob, at: Date(), commandId: commandID) }
        snapshot.tasks[index].suspiciousFiles = []
        emit(.suspiciousFilesAccepted(.init(taskId: task.id, files: task.suspiciousFiles, by: .human, commandId: commandID)), projectID: task.projectId, commandID: commandID)
    }
    private var accepted: [TaskID: [AcceptedFile]] = [:]

    private func publish(_ event: EventEnvelope) {
        journal.append(event)
        for continuation in continuations.values { continuation.yield(event) }
    }

    public static func fixture() -> Snapshot {
        let now = Date(timeIntervalSince1970: 1_791_100_000)
        let projects = [
            ProjectSummary(id: "kaban", name: "Kaban", path: "~/Projects/kaban", mascotSeed: "kaban"),
            ProjectSummary(id: "shop", name: "Магазин", path: "~/Projects/shop", mascotSeed: "shop")
        ]
        let stages = [
            StageSummary(id: "backlog", name: "Backlog", kind: .queue, display: .init(order: 0)),
            StageSummary(id: "dev", name: "Dev", kind: .agent, display: .init(order: 1), wip: 2, model: "composer-1"),
            StageSummary(id: "test", name: "Test", kind: .gate, display: .init(order: 2)),
            StageSummary(id: "review", name: "Human Review", kind: .human, display: .init(order: 3)),
            StageSummary(id: "done", name: "Done", kind: .terminal, display: .init(order: 4))
        ]
        return Snapshot(seq: 0, projects: projects,
                        pipelines: projects.map { PipelineSummary(projectId: $0.id, versionHash: "fixture-v1", stages: stages) },
                        tasks: [
                            TaskCard(id: "23", projectId: "kaban", title: "Подпись релизной сборки", stageId: "dev", state: .running, branch: "kaban/task-23", attempt: 1, maxAttempts: 3, model: "composer-1", hasAcceptanceCriteria: true, updatedAt: now),
                            TaskCard(id: "24", projectId: "kaban", title: "Поиск задач на доске", stageId: "backlog", state: .queued(nil), hasAcceptanceCriteria: true, updatedAt: now),
                            TaskCard(id: "25", projectId: "kaban", title: "Проверить настройки проекта", stageId: "review", state: .waitingHuman(.review), updatedAt: now),
                            TaskCard(id: "52", projectId: "shop", title: "Интеграция платёжного шлюза", stageId: "dev", state: .waitingHuman(.suspiciousFiles), suspiciousFiles: [.init(path: ".env.local", rule: .pattern, pattern: ".env*", sizeBytes: 412, isText: true, blob: "fixture-blob")], updatedAt: now),
                            TaskCard(id: "53", projectId: "shop", title: "Индексы поиска по SKU", stageId: "test", state: .gating, updatedAt: now)
                        ], stageLoad: [.init(projectId: "kaban", stageId: "dev", wipUsed: 1, wipLimit: 2)])
    }
}
