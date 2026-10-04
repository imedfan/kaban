import Foundation
import KabanProtocol

/// Transport boundary shared by the fixture client and the future XPC adapter.
/// Commands return acknowledgements; only snapshots and events change the board.
@MainActor public protocol KabanClient: AnyObject {
    func getSnapshot() async throws -> Snapshot
    func events() -> AsyncStream<EventEnvelope>
    func send(_ command: Command, commandId: CommandID) async throws -> CommandResult
}

@MainActor public final class MockKabanClient: KabanClient {
    private var snapshot: Snapshot
    private var continuations: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]
    private var journal: [EventEnvelope] = []
    private var pausedStates: [TaskID: TaskState] = [:]

    public init(snapshot: Snapshot = MockKabanClient.fixture()) { self.snapshot = snapshot }
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
        switch command {
        case .getTaskDetail(let id):
            guard let task = snapshot.tasks.first(where: { $0.id == id }) else { return missingTask() }
            let feed = journal.compactMap { envelope -> FeedItem? in
                guard case .taskUpdated(let updated) = envelope.event, updated.id == id else { return nil }
                return FeedItem(id: String(envelope.seq), at: envelope.at, kind: "transition", text: CardPresentation(state: updated.state).label)
            }
            return .taskDetail(TaskDetail(seq: snapshot.seq, task: task, feed: feed, runs: [], suspiciousFiles: task.suspiciousFiles))
        case .pauseTask(let id):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard snapshot.tasks[index].state == .running else { return invalidState() }
            pausedStates[id] = snapshot.tasks[index].state
            return update(index, state: .paused, commandId: commandId)
        case .resumeTask(let id):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard snapshot.tasks[index].state == .paused else { return invalidState() }
            return update(index, state: pausedStates.removeValue(forKey: id) ?? .queued(nil), commandId: commandId)
        default:
            return .error(CommandError(code: "unknown_command", message: "Это действие пока недоступно в демонстрационном клиенте."))
        }
    }
    private func missingTask() -> CommandResult { .error(CommandError(code: "task_not_found", message: "Задача не найдена.")) }
    private func invalidState() -> CommandResult { .error(CommandError(code: "invalid_state", message: "Состояние задачи изменилось.")) }
    private func update(_ index: Int, state: TaskState, commandId: CommandID) -> CommandResult {
        let previousState = snapshot.tasks[index].state
        snapshot.seq += 1
        snapshot.tasks[index].state = state
        snapshot.tasks[index].updatedAt = Date()
        let envelope = EventEnvelope(seq: snapshot.seq, at: snapshot.tasks[index].updatedAt,
                                     projectId: snapshot.tasks[index].projectId, commandId: commandId,
                                     event: .taskUpdated(snapshot.tasks[index]))
        publish(envelope)
        let task = snapshot.tasks[index]
        if let loadIndex = snapshot.stageLoad.firstIndex(where: { $0.projectId == task.projectId && $0.stageId == task.stageId }),
           let kind = snapshot.pipelines.first(where: { $0.projectId == task.projectId })?.stages.first(where: { $0.id == task.stageId })?.kind {
            let delta = (state.status.occupiesWIP(in: kind) ? 1 : 0) - (previousState.status.occupiesWIP(in: kind) ? 1 : 0)
            if delta != 0 {
                snapshot.stageLoad[loadIndex].wipUsed = max(0, snapshot.stageLoad[loadIndex].wipUsed + delta)
                snapshot.seq += 1
                publish(EventEnvelope(seq: snapshot.seq, at: Date(), projectId: task.projectId, commandId: commandId,
                                      event: .stageLoadChanged(snapshot.stageLoad[loadIndex])))
            }
        }
        return .ok
    }

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
