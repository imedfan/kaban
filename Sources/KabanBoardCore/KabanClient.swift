import Foundation
import KabanProtocol

/// Transport boundary shared by the fixture client and the daemon adapter.
/// Commands return acknowledgements; only snapshots and events change the board.
@MainActor public protocol KabanClient: AnyObject {
    func getSnapshot() async throws -> Snapshot
    func synchronize() async throws -> SnapshotReplacement
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error>
    func events() -> AsyncStream<EventEnvelope>
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply
    func capabilities() async throws -> DaemonCapabilities
    func readLog(runId: RunID, fromOffset: Int64, limit: Int) async throws -> LogPage
    func tailLog(runId: RunID, fromOffset: Int64) -> AsyncThrowingStream<LogBatch, Error>
}

public enum KabanClientUpdate: Sendable {
    case capabilities(DaemonCapabilities)
    case event(EventEnvelope)
    case replacement(SnapshotReplacement)
    case connection(DaemonConnectionState)
    case ephemeral(EphemeralEnvelope)
}
extension KabanClient {
    public func synchronize() async throws -> SnapshotReplacement {
        throw CommandError(code: CommandError.unsupportedOperationCode, message: "Источник данных не поддерживает восстановление сессии.")
    }
    public func send(_ command: Command, commandId: CommandID) async throws -> CommandResult {
        try await send(.init(commandId: commandId, command: command)).result
    }
    public func readLog(runId: RunID, fromOffset: Int64, limit: Int = DaemonWire.maxPageSize) async throws -> LogPage {
        throw CommandError(code: CommandError.unsupportedOperationCode, message: "Источник данных не поддерживает чтение логов.")
    }
    public func tailLog(runId: RunID, fromOffset: Int64) -> AsyncThrowingStream<LogBatch, Error> {
        AsyncThrowingStream { $0.finish(throwing: CommandError(code: CommandError.unsupportedOperationCode, message: "Источник данных не поддерживает чтение логов.")) }
    }
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
    private let sessionId = UUID()
    private var continuations: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]
    private var journal: [EventEnvelope] = []
    private var bodies: [TaskID: String] = [:]
    private var runs: [TaskID: [RunSummary]] = [:]
    private var currentEvents: [EphemeralEvent] = []
    private var receipts: [CommandID: (CommandEnvelope, CommandReply)] = [:]
    private var notes: [TaskID: [FeedItem]] = [:]
    private var pausedStates: [TaskID: TaskState] = [:]
    private var questions: [TaskID: [HumanRequest]] = [:]
    private var answeredQuestions: Set<HumanRequestID> = []


    public init(snapshot: Snapshot = MockKabanClient.fixture(), taskBodies: [TaskID: String] = [:],
                taskRuns: [TaskID: [RunSummary]] = [:], currentEvents: [EphemeralEvent] = [],
                humanRequests: [TaskID: [HumanRequest]] = [:]) {
        self.snapshot = snapshot; self.bodies = taskBodies; self.runs = taskRuns; self.currentEvents = currentEvents
        self.questions = humanRequests
        for (id, requests) in humanRequests {
            notes[id] = requests.map { .init(id: $0.requestId.rawValue, at: Date(), kind: "question", text: $0.question, runId: $0.runId) }
        }
    }
    public func getSnapshot() async throws -> Snapshot { snapshot }
    public func synchronize() async throws -> SnapshotReplacement {
        let current = currentEvents.enumerated().map { index, event in
            EphemeralEnvelope(cursor: .init(sessionId: sessionId, offset: Int64(index + 1)), afterSeq: snapshot.seq, at: Date(), event: event)
        }
        return .init(snapshot: snapshot, cursor: .init(sessionId: sessionId, offset: Int64(current.count)), current: current)
    }
    public func events() -> AsyncStream<EventEnvelope> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }
    public func capabilities() async throws -> DaemonCapabilities {
        let supported: Set<CommandName> = [.getTaskDetail, .createTask, .editTask, .setPriority, .moveTask, .cancelTask, .pauseTask, .resumeTask, .retryStage, .answerHuman, .approve, .requestChanges, .reject, .acceptSuspiciousFiles, .pauseAll, .resumeAll, .pauseProject, .resumeProject, .setMascot]
        return .init(operations: ["snapshot", "command", "subscribe", "synchronize"].map { .init(name: $0, supported: true) },
                     commands: CommandName.allCases.map { .init(name: $0.rawValue, support: supported.contains($0) ? .supported : .unsupported) })
    }
    public func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        let commandId = envelope.commandId
        guard envelope.protocolVersion == KabanCoding.protocolVersion else {
            return .init(commandId: commandId, seq: nil, result: .error(.init(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
        }
        if let receipt = receipts[commandId] {
            guard receipt.0 == envelope else { return .init(commandId: commandId, seq: nil, result: .error(CommandError(code: "command_id_conflict", message: "Этот идентификатор уже использован для другого действия."))) }
            return receipt.1
        }
        let result = execute(envelope.command, commandId: commandId)
        let reply = CommandReply(commandId: commandId, seq: journal.last(where: { $0.commandId == commandId })?.seq, result: result)
        receipts[commandId] = (envelope, reply)
        return reply
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
            return .taskDetail(TaskDetail(seq: snapshot.seq, task: task, feed: feed, runs: runs[id] ?? [], humanRequests: questions[id] ?? [], suspiciousFiles: task.suspiciousFiles, acceptedFiles: accepted[id] ?? [], body: bodies[id], wipRestoreOperations: []))
        case .answerHuman(let id, let text, let requestID):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            let card = snapshot.tasks[index]
            guard case .waitingHuman = card.state,
                  snapshot.pipelines.first(where: { $0.projectId == card.projectId })?.stages.first(where: { $0.id == card.stageId })?.kind == .agent else { return invalidState() }
            let current = questions[id]?.last(where: { !answeredQuestions.contains($0.requestId) })
            if let requestID, current?.requestId != requestID { return invalidState() }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\0") else {
                return .error(.init(code: "invalid_request", message: "Напишите ответ или замечание агенту."))
            }
            if let maximum = card.maxAttempts, card.attempt >= maximum {
                guard maximum < Int.max else { return invalidState() }
                snapshot.tasks[index].maxAttempts = maximum + 1
            }
            if let current { answeredQuestions.insert(current.requestId) }
            if card.state == .waitingHuman(.suspiciousFiles) { snapshot.tasks[index].suspiciousFiles = [] }
            notes[id, default: []].append(.init(id: commandId.uuidString, at: Date(), kind: "answer", text: text, runId: current?.runId))
            emit(.humanAnswered(.init(taskId: id, requestId: current?.requestId ?? requestID, text: text)), projectID: card.projectId, commandID: commandId)
            return update(index, state: .queued(nil), commandId: commandId)
        case .approve(let id), .requestChanges(let id, _, _), .reject(let id, _, _):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }),
                  let pipeline = snapshot.pipelines.first(where: { $0.projectId == snapshot.tasks[index].projectId }) else { return missingTask() }
            let card = snapshot.tasks[index]
            guard case .waitingHuman = card.state,
                  let source = pipeline.stages.first(where: { $0.id == card.stageId }) else { return invalidState() }
            let target: StageID
            switch command {
            case .approve:
                guard source.kind == .human, card.state == .waitingHuman(.review), let next = source.onSuccess,
                      pipeline.stages.contains(where: { $0.id == next }) else { return invalidState() }
                target = next
            case .requestChanges(_, let comments, let requested):
                guard [.human, .gate, .merge].contains(source.kind), !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !comments.contains("\0"), let requested = requested ?? pipeline.defaultReturnStage,
                      HumanReviewContext.returnTargets(card: card, pipeline: pipeline).contains(where: { $0.id == requested }) else { return invalidState() }
                target = requested
                notes[id, default: []].append(.init(id: commandId.uuidString, at: Date(), kind: "review_comment", text: comments))
            case .reject(_, .cancel, let keep):
                guard source.kind == .human, card.state == .waitingHuman(.review) else { return invalidState() }
                acceptDemoFiles(index, commandID: commandId)
                snapshot.tasks[index].branch = keep && card.branch != nil ? "refs/kaban/archive/" + id.rawValue : nil
                return update(index, state: .cancelled, commandId: commandId)
            case .reject(_, .stage(let requested), _):
                guard source.kind == .human, card.state == .waitingHuman(.review),
                      HumanReviewContext.returnTargets(card: card, pipeline: pipeline).contains(where: { $0.id == requested }) else { return invalidState() }
                target = requested; acceptDemoFiles(index, commandID: commandId)
            default: return invalidState()
            }
            if case .requestChanges = command { snapshot.tasks[index].suspiciousFiles = [] }
            if let stage = pipeline.stages.first(where: { $0.id == target }) {
                snapshot.tasks[index].attempt = 0; snapshot.tasks[index].maxAttempts = stage.maxAttempts
                snapshot.tasks[index].model = stage.model
            }
            return update(index, state: .queued(nil), commandId: commandId, stageID: target)
        case .setMascot(let projectID, let seed):
            guard let index = snapshot.projects.firstIndex(where: { $0.id == projectID }) else {
                return .error(.init(code: "project_not_found", message: "Проект не найден."))
            }
            guard !seed.contains("\0") else { return .error(.init(code: "invalid_request", message: "Seed содержит NUL.")) }
            snapshot.projects[index].mascotSeed = seed
            emit(.projectUpdated(snapshot.projects[index]), projectID: projectID, commandID: commandId)
            return .ok
        case .createTask(let projectID, let title, let body):
            guard snapshot.projects.contains(where: { $0.id == projectID }) else { return .error(CommandError(code: "project_not_found", message: "Проект не найден.")) }
            guard let pipeline = snapshot.pipelines.first(where: { $0.projectId == projectID }),
                  let queue = pipeline.stages.first(where: { $0.kind == .queue }) else { return invalidState() }
            let draft = DemoTaskDraft(title: title, body: body)
            guard draft.canSubmit, !body.contains("\0") else { return .error(CommandError(code: "invalid_request", message: "Укажите заголовок задачи; поля не должны содержать NUL.")) }
            let id = TaskID(rawValue: UUID().uuidString)
            let task = TaskCard(id: id, projectId: projectID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), stageId: queue.id,
                                state: .queued(nil), hasAcceptanceCriteria: TaskMarkdown.hasAcceptanceCriteria(in: body), updatedAt: Date())
            snapshot.tasks.append(task)
            bodies[id] = body
            emit(.taskCreated(task), projectID: projectID, commandID: commandId)
            return .taskCreated(id)
        case .editTask(let id, let title, let body):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard TaskActions.canEdit(snapshot.tasks[index]) else { return invalidState() }
            guard title != nil || body != nil else { return .error(CommandError(code: "invalid_request", message: "Нет изменений.")) }
            if let body, body.contains("\0") { return .error(CommandError(code: "invalid_request", message: "Описание содержит NUL.")) }
            if let title, !DemoTaskDraft(title: title).canSubmit { return .error(CommandError(code: "invalid_request", message: "Укажите заголовок задачи.")) }
            if body != nil, bodies[id] == nil { return .error(CommandError(code: "incomplete_projection", message: "Описание задачи неизвестно.")) }
            if let title { snapshot.tasks[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let body {
                snapshot.tasks[index].hasAcceptanceCriteria = TaskMarkdown.hasAcceptanceCriteria(in: body)
                bodies[id] = body
            }
            snapshot.tasks[index].updatedAt = Date()
            emit(.taskEdited(snapshot.tasks[index]), projectID: snapshot.tasks[index].projectId, commandID: commandId)
            emit(.taskUpdated(snapshot.tasks[index]), projectID: snapshot.tasks[index].projectId, commandID: commandId)
            return .ok
        case .setPriority(let id, let priority):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard TaskActions.canSetPriority(snapshot.tasks[index]) else { return invalidState() }
            snapshot.tasks[index].priority = priority
            snapshot.tasks[index].updatedAt = Date()
            emit(.taskUpdated(snapshot.tasks[index]), projectID: snapshot.tasks[index].projectId, commandID: commandId)
            return .ok
        case .acceptSuspiciousFiles(let id, let shown):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }),
                  snapshot.tasks[index].state == .waitingHuman(.suspiciousFiles),
                  let pipeline = snapshot.pipelines.first(where: { $0.projectId == snapshot.tasks[index].projectId }),
                  let next = pipeline.stages.first(where: { $0.id == snapshot.tasks[index].stageId })?.onSuccess,
                  let target = pipeline.stages.first(where: { $0.id == next }) else { return invalidState() }
            let current = snapshot.tasks[index].suspiciousFiles.map { FileBlobRef(path: $0.path, blob: $0.blob) }
            guard Set(current) == Set(shown), shown.count == Set(shown).count else {
                return .error(.init(code: CommandError.staleSuspiciousFilesCode, message: "Набор файлов изменился — ничего не принято."))
            }
            acceptDemoFiles(index, commandID: commandId)
            return update(index, state: target.kind == .terminal ? .done : .queued(nil), commandId: commandId, stageID: next)
        case .moveTask(let id, let targetID):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            let task = snapshot.tasks[index]
            guard snapshot.projects.first(where: { $0.id == task.projectId })?.availability == .available,
                  let pipeline = snapshot.pipelines.first(where: { $0.projectId == task.projectId }), pipeline.isValid,
                  let target = pipeline.stages.first(where: { $0.id == targetID }) else { return invalidState() }
            guard TaskActions.moveDecision(card: task, target: target, pipeline: pipeline).isAllowed else { return invalidState() }
            pausedStates.removeValue(forKey: id)
            snapshot.tasks[index].attempt = 0
            snapshot.tasks[index].maxAttempts = target.maxAttempts
            snapshot.tasks[index].model = target.model
            acceptDemoFiles(index, commandID: commandId)
            return update(index, state: .queued(nil), commandId: commandId, stageID: targetID)
        case .cancelTask(let id, let keepBranch):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard TaskActions.canCancel(snapshot.tasks[index]) else { return invalidState() }
            pausedStates.removeValue(forKey: id)
            acceptDemoFiles(index, commandID: commandId)
            if keepBranch, snapshot.tasks[index].branch != nil {
                notes[id, default: []].append(FeedItem(id: UUID().uuidString, at: Date(), kind: "summary", text: "Демо: выбрано сохранение ветки при отмене."))
            } else { snapshot.tasks[index].branch = nil }
            return update(index, state: .cancelled, commandId: commandId)
        case .pauseTask(let id):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard TaskActions.canPause(snapshot.tasks[index]) else { return invalidState() }
            pausedStates[id] = snapshot.tasks[index].state
            return update(index, state: .paused, commandId: commandId)
        case .resumeTask(let id):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard snapshot.tasks[index].state == .paused else { return invalidState() }
            let restored: TaskState = pausedStates.removeValue(forKey: id) == .waitingHuman(.review) ? .waitingHuman(.review) : .queued(nil)
            return update(index, state: restored, commandId: commandId)
        case .retryStage(let id, let grant):
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return missingTask() }
            guard TaskActions.canRetry(snapshot.tasks[index]), grant.map({ $0 >= 0 }) ?? true else { return invalidState() }
            if let maximum = snapshot.tasks[index].maxAttempts {
                let increased = maximum.addingReportingOverflow(grant ?? 0)
                guard !increased.overflow else { return invalidState() }
                let exhausted = snapshot.tasks[index].attempt >= increased.partialValue
                guard !exhausted || increased.partialValue < Int.max else { return invalidState() }
                snapshot.tasks[index].maxAttempts = increased.partialValue + (exhausted ? 1 : 0)
            }
            acceptDemoFiles(index, commandID: commandId)
            return update(index, state: .queued(nil), commandId: commandId)
        case .pauseAll, .resumeAll, .pauseProject, .resumeProject:
            let paused: Bool, project: ProjectID?
            switch command {
            case .pauseAll: paused = true; project = nil
            case .resumeAll: paused = false; project = nil
            case .pauseProject(let id): paused = true; project = id
            case .resumeProject(let id): paused = false; project = id
            default: return invalidState()
            }
            if let project, !snapshot.projects.contains(where: { $0.id == project }) { return invalidState() }
            let flag: SchedulerFlag = project.map { .projectPaused($0) } ?? .macPaused
            snapshot.schedulerFlags.removeAll { $0 == flag }
            if paused { snapshot.schedulerFlags.append(flag) }
            emit(.settingsChanged(.init(key: project == nil ? "mac.paused" : "project.paused",
                                        value: paused ? "true" : "false", schedulerFlags: snapshot.schedulerFlags)),
                 projectID: project, commandID: commandId)
            return .ok
        default:
            return .error(CommandError(code: "unknown_command", message: "Это действие пока недоступно в демонстрационном клиенте."))
        }
    }
    private func missingTask() -> CommandResult { .error(CommandError(code: "task_not_found", message: "Задача не найдена.")) }
    private func invalidState() -> CommandResult { .error(CommandError(code: "invalid_state", message: "Состояние задачи изменилось.")) }
    private func update(_ index: Int, state: TaskState, commandId: CommandID, stageID: StageID? = nil) -> CommandResult {
        let previous = snapshot.tasks[index]
        snapshot.tasks[index].state = state
        snapshot.tasks[index].runsSinceHuman = 0
        if let stageID { snapshot.tasks[index].stageId = stageID }
        let stage = snapshot.pipelines.first { $0.projectId == previous.projectId }?.stages.first { $0.id == snapshot.tasks[index].stageId }
        if stage?.kind != .merge || [.done, .cancelled].contains(state.status) { snapshot.tasks[index].mergeQueueSequence = nil }
        else if previous.stageId != snapshot.tasks[index].stageId { snapshot.tasks[index].mergeQueueSequence = snapshot.seq + 1 }
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
    private func emit(_ event: JournalEvent, projectID: ProjectID?, commandID: CommandID) {
        snapshot.seq += 1
        publish(EventEnvelope(seq: snapshot.seq, at: Date(), projectId: projectID, commandId: commandID, event: event))
    }
    private func acceptDemoFiles(_ index: Int, commandID: CommandID) {
        let task = snapshot.tasks[index]
        guard task.state == .waitingHuman(.suspiciousFiles), !task.suspiciousFiles.isEmpty else { return }
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
