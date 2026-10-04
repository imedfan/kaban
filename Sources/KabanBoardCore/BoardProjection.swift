import Foundation
import KabanProtocol

/// Подписка на журнал. `projectIds == nil` — все проекты, как делает приложение.
public struct SubscriptionID: Hashable, Sendable {
    public var projectIds: [ProjectID]?

    public init(projectIds: [ProjectID]? = nil) {
        self.projectIds = projectIds
    }

    public static let all = SubscriptionID(projectIds: nil)
}

public struct SubscriptionCursor: Equatable, Sendable {
    public var lastAppliedSeq: Seq
    public var needsResync: Bool

    public init(lastAppliedSeq: Seq, needsResync: Bool = false) {
        self.lastAppliedSeq = lastAppliedSeq
        self.needsResync = needsResync
    }
}

public enum JournalApplyResult: Equatable, Sendable {
    case applied
    /// Неизвестный `type`: состояние не меняется, `seq` съедается, чтобы следующий не выглядел дыркой.
    case ignored
    case duplicate
    case gap(expected: Seq, received: Seq)
    /// Уже ждём снимок, журнальное событие не применяется.
    case needsResync
}

public enum EphemeralApplyResult: Equatable, Sendable {
    case applied
    case ignored
    case resyncRequired
}

public struct TransitionHint: Equatable, Sendable {
    public var seq: Seq
    public var at: Date
    public var transition: TaskTransition

    public init(seq: Seq, at: Date, transition: TaskTransition) {
        self.seq = seq
        self.at = at
        self.transition = transition
    }
}

/// Строка ленты доски. Карточку не описывает: её держат `taskCreated` / `taskUpdated` / `taskEdited`.
public struct BoardFeedItem: Equatable, Sendable {
    public var seq: Seq
    public var at: Date
    public var projectId: ProjectID?
    public var commandId: CommandID?
    public var event: JournalEvent

    public init(seq: Seq, at: Date, projectId: ProjectID?, commandId: CommandID?, event: JournalEvent) {
        self.seq = seq
        self.at = at
        self.projectId = projectId
        self.commandId = commandId
        self.event = event
    }

    public var taskId: TaskID? {
        switch event {
        case .taskTransitioned(let transition): transition.taskId
        case .humanRequested(let request): request.taskId
        case .humanAnswered(let answer): answer.taskId
        case .gitDenied(let denial): denial.taskId
        case .incidentOpened(let incident): incident.taskId
        case .suspiciousFilesFound(let found): found.taskId
        case .suspiciousFilesAccepted(let accepted): accepted.taskId
        default: nil
        }
    }
}

public struct BoardColumn: Equatable, Sendable {
    public var stage: StageSummary
    public var taskIds: [TaskID]

    public init(stage: StageSummary, taskIds: [TaskID]) {
        self.stage = stage
        self.taskIds = taskIds
    }
}

public struct BoardLane: Equatable, Sendable {
    public var project: ProjectSummary
    public var columns: [BoardColumn]

    public init(project: ProjectSummary, columns: [BoardColumn]) {
        self.project = project
        self.columns = columns
    }
}

/// Эфемерное состояние. Журнальный `seq` его не двигает.
public struct EphemeralBoardState: Equatable, Sendable {
    public var schedulerFlags: [SchedulerFlag]
    public var modelFlags: [ModelFlag]
    public var quota: QuotaState?
    public var modelCatalog: [ModelInfo]
    public var runnerCheck: RunnerCheck?
    public var pipelineDrafts: [ProjectID: PipelineDraftValidation]
    public var runProgress: [RunID: RunProgress]

    public init(
        schedulerFlags: [SchedulerFlag] = [],
        modelFlags: [ModelFlag] = [],
        quota: QuotaState? = nil,
        modelCatalog: [ModelInfo] = [],
        runnerCheck: RunnerCheck? = nil,
        pipelineDrafts: [ProjectID: PipelineDraftValidation] = [:],
        runProgress: [RunID: RunProgress] = [:]
    ) {
        self.schedulerFlags = schedulerFlags
        self.modelFlags = modelFlags
        self.quota = quota
        self.modelCatalog = modelCatalog
        self.runnerCheck = runnerCheck
        self.pipelineDrafts = pipelineDrafts
        self.runProgress = runProgress
    }
}

public struct ProjectBadgeCounts: Equatable, Sendable {
    public var waitingHuman: Int
    /// Открытые инциденты, которые проекция видела в журнале после последнего снимка.
    public var openIncidents: Int

    public init(waitingHuman: Int, openIncidents: Int) {
        self.waitingHuman = waitingHuman
        self.openIncidents = openIncidents
    }
}

/// Проекция доски: снимок плюс применённые конверты.
public struct BoardProjection: Equatable, Sendable {
    public private(set) var stateSeq: Seq
    public private(set) var cursors: [SubscriptionID: SubscriptionCursor]
    public private(set) var resyncRequested: Bool
    public private(set) var projects: [ProjectID: ProjectSummary]
    public private(set) var projectOrder: [ProjectID]
    public private(set) var pipelines: [ProjectID: PipelineSummary]
    public private(set) var tasks: [TaskID: TaskCard]
    public private(set) var taskOrder: [TaskID]
    public private(set) var feed: [BoardFeedItem]
    public private(set) var transitionHints: [TaskID: TransitionHint]
    public private(set) var ephemeral: EphemeralBoardState
    public private(set) var openIncidentCount: Int
    public private(set) var incidents: [IncidentID: Incident]
    /// Загрузка стадий из снимка; между снимками её двигает `stageLoadChanged`. Клиент WIP не считает.
    public private(set) var stageLoad: [StageLoad]
    public private(set) var pending: PendingCommands
    private var appliedSeqs: Set<Seq>
    private var resolvedIncidentIds: Set<IncidentID>

    public init(snapshot: Snapshot, subscription: SubscriptionID = .all) {
        stateSeq = snapshot.seq
        cursors = [subscription: SubscriptionCursor(lastAppliedSeq: snapshot.seq)]
        resyncRequested = false
        projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        projectOrder = snapshot.projects.map(\.id)
        pipelines = Dictionary(uniqueKeysWithValues: snapshot.pipelines.map { ($0.projectId, $0) })
        tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        taskOrder = snapshot.tasks.map(\.id)
        feed = []
        transitionHints = [:]
        ephemeral = EphemeralBoardState(
            schedulerFlags: snapshot.schedulerFlags,
            modelFlags: snapshot.modelFlags,
            quota: snapshot.quota
        )
        openIncidentCount = snapshot.openIncidentCount
        incidents = [:]
        stageLoad = snapshot.stageLoad
        pending = PendingCommands()
        appliedSeqs = []
        resolvedIncidentIds = []
    }

    public var needsResync: Bool {
        resyncRequested || cursors.values.contains { $0.needsResync }
    }

    public func cursor(for subscription: SubscriptionID) -> SubscriptionCursor? {
        cursors[subscription]
    }

    public mutating func openSubscription(_ subscription: SubscriptionID, from seq: Seq? = nil) {
        cursors[subscription] = SubscriptionCursor(lastAppliedSeq: seq ?? stateSeq)
    }

    /// Снимок вместо текущего состояния. «Отправлено» сохраняется: ответ мог ещё не доехать.
    /// Курсоры переводятся на `snapshot.seq`.
    public mutating func replace(with snapshot: Snapshot) {
        let kept = pending
        let subscriptionIDs = Set(cursors.keys).union([.all])
        self = BoardProjection(snapshot: snapshot)
        pending = kept
        for id in subscriptionIDs {
            cursors[id] = SubscriptionCursor(lastAppliedSeq: snapshot.seq)
        }
    }

    public mutating func markSent(commandId: CommandID, taskId: TaskID, at sentAt: Date) {
        pending.markSent(commandId: commandId, taskId: taskId, at: sentAt)
    }

    public mutating func noteCommandError(_ commandId: CommandID) {
        pending.clear(commandId: commandId)
    }

    public func isSent(_ taskId: TaskID) -> Bool {
        pending.isSent(taskId)
    }

    @discardableResult
    public mutating func apply(_ envelope: EventEnvelope, subscription: SubscriptionID = .all) -> JournalApplyResult {
        guard var cursor = cursors[subscription] else {
            resyncRequested = true
            return .needsResync
        }
        if envelope.seq <= cursor.lastAppliedSeq {
            return .duplicate
        }
        if cursor.needsResync || resyncRequested {
            return .needsResync
        }
        if envelope.seq > cursor.lastAppliedSeq + 1 {
            cursor.needsResync = true
            cursors[subscription] = cursor
            return .gap(expected: cursor.lastAppliedSeq + 1, received: envelope.seq)
        }
        let result: JournalApplyResult
        if appliedSeqs.contains(envelope.seq) {
            result = .applied
        } else {
            result = reduce(envelope)
            appliedSeqs.insert(envelope.seq)
            stateSeq = envelope.seq
        }
        cursor.lastAppliedSeq = envelope.seq
        cursors[subscription] = cursor
        return result
    }

    /// Эфемерное событие не двигает `seq` и не меняет карточки.
    @discardableResult
    public mutating func apply(_ event: EphemeralEvent) -> EphemeralApplyResult {
        switch event {
        case .schedulerFlagsChanged(let flags):
            ephemeral.schedulerFlags = flags
        case .modelFlagsChanged(let flags):
            ephemeral.modelFlags = flags
        case .quotaUpdated(let quota):
            ephemeral.quota = quota
        case .modelCatalogChanged(let models):
            ephemeral.modelCatalog = models
        case .runnerChecked(let check):
            ephemeral.runnerCheck = check
        case .pipelineDraftValidated(let draft):
            ephemeral.pipelineDrafts[draft.projectId] = draft
        case .runProgress(let progress):
            ephemeral.runProgress[progress.runId] = progress
        case .resyncRequired:
            resyncRequested = true
            return .resyncRequired
        case .unknown:
            return .ignored
        }
        return .applied
    }

    public func lanes(orderedBy visibleIDs: [ProjectID]? = nil) -> [BoardLane] {
        let order = visibleIDs ?? projectOrder
        return order.compactMap { id in
            guard let project = projects[id] else { return nil }
            return BoardLane(project: project, columns: columns(for: id))
        }
    }

    public func feed(for taskId: TaskID) -> [BoardFeedItem] {
        feed.filter { $0.taskId == taskId }
    }

    /// Бейджи считаются по проекции, видимость дорожки на них не влияет.
    ///
    /// Счётчик инцидентов — `ProjectSummary.openIncidentCount` (снимок и `projectUpdated`).
    /// `incidentOpened` / `incidentResolved` сдвигают поле проекта, пока демон не пришлёт
    /// новый `projectUpdated` с уже посчитанным значением.
    public func badgeCounts(for projectId: ProjectID) -> ProjectBadgeCounts {
        let waiting = tasks.values.filter { $0.projectId == projectId && $0.state.status == .waitingHuman }.count
        let open = projects[projectId]?.openIncidentCount ?? 0
        return ProjectBadgeCounts(waitingHuman: waiting, openIncidents: open)
    }

    public func load(projectId: ProjectID, stageId: StageID) -> StageLoad? {
        stageLoad.first { $0.projectId == projectId && $0.stageId == stageId }
    }

    private func columns(for projectId: ProjectID) -> [BoardColumn] {
        guard let pipeline = pipelines[projectId] else { return [] }
        return DropRules.orderedStages(pipeline).map { stage in
            let ids = taskOrder.filter { tasks[$0]?.projectId == projectId && tasks[$0]?.stageId == stage.id }
            return BoardColumn(stage: stage, taskIds: ids)
        }
    }

    private mutating func reduce(_ envelope: EventEnvelope) -> JournalApplyResult {
        switch envelope.event {
        case .taskCreated(let card), .taskEdited(let card):
            replaceCard(card)
            return .applied
        case .taskUpdated(let card):
            replaceCard(card)
            if let commandId = envelope.commandId {
                pending.clear(commandId: commandId)
            }
            return .applied
        case .taskTransitioned(let transition):
            transitionHints[transition.taskId] = TransitionHint(seq: envelope.seq, at: envelope.at, transition: transition)
            appendFeed(envelope)
            return .applied
        case .projectAdded(let project):
            projects[project.id] = project
            if !projectOrder.contains(project.id) { projectOrder.append(project.id) }
            appendFeed(envelope)
            return .applied
        case .projectUpdated(let project):
            projects[project.id] = project
            if !projectOrder.contains(project.id) { projectOrder.append(project.id) }
            appendFeed(envelope)
            return .applied
        case .projectRemoved(let id):
            removeProject(id)
            appendFeed(envelope)
            return .applied
        case .pipelineApplied(let pipeline):
            pipelines[pipeline.projectId] = pipeline
            appendFeed(envelope)
            return .applied
        case .incidentOpened(let incident):
            if incidents[incident.id] == nil {
                openIncidentCount += 1
                adjustOpenIncidents(incident.projectId, by: 1)
            }
            incidents[incident.id] = incident
            appendFeed(envelope)
            return .applied
        case .incidentResolved(let resolved):
            if !resolvedIncidentIds.contains(resolved.incidentId) {
                resolvedIncidentIds.insert(resolved.incidentId)
                if var incident = incidents[resolved.incidentId] {
                    if incident.resolvedAt == nil {
                        incident.resolvedAt = envelope.at
                        incidents[resolved.incidentId] = incident
                        if openIncidentCount > 0 { openIncidentCount -= 1 }
                        adjustOpenIncidents(incident.projectId, by: -1)
                    }
                } else {
                    if openIncidentCount > 0 { openIncidentCount -= 1 }
                    if let projectId = envelope.projectId {
                        adjustOpenIncidents(projectId, by: -1)
                    }
                }
            }
            appendFeed(envelope)
            return .applied
        case .stageLoadChanged(let load):
            if let index = stageLoad.firstIndex(where: { $0.projectId == load.projectId && $0.stageId == load.stageId }) {
                stageLoad[index] = load
            } else {
                stageLoad.append(load)
            }
            appendFeed(envelope)
            return .applied
        case .unknown:
            return .ignored
        default:
            appendFeed(envelope)
            return .applied
        }
    }

    private mutating func replaceCard(_ card: TaskCard) {
        if tasks[card.id] == nil {
            taskOrder.append(card.id)
        }
        tasks[card.id] = card
    }

    private mutating func removeProject(_ id: ProjectID) {
        let removedOpen = projects[id]?.openIncidentCount ?? 0
        projects.removeValue(forKey: id)
        projectOrder.removeAll { $0 == id }
        pipelines.removeValue(forKey: id)
        let doomed = Set(tasks.compactMap { taskId, card in card.projectId == id ? taskId : nil })
        for taskId in doomed {
            tasks.removeValue(forKey: taskId)
            transitionHints.removeValue(forKey: taskId)
            pending.clear(taskId: taskId)
        }
        taskOrder.removeAll { doomed.contains($0) }
        incidents = incidents.filter { $0.value.projectId != id }
        openIncidentCount = max(0, openIncidentCount - removedOpen)
    }

    private mutating func adjustOpenIncidents(_ projectId: ProjectID, by delta: Int) {
        guard var project = projects[projectId], delta != 0 else { return }
        project.openIncidentCount = max(0, project.openIncidentCount + delta)
        projects[projectId] = project
    }

    private mutating func appendFeed(_ envelope: EventEnvelope) {
        feed.append(BoardFeedItem(
            seq: envelope.seq,
            at: envelope.at,
            projectId: envelope.projectId,
            commandId: envelope.commandId,
            event: envelope.event
        ))
    }
}
