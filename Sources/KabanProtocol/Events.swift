import Foundation

// MARK: - Журнальные события (§5): имеют `seq`, переживают переподключение.

public struct EventEnvelope: Codable, Hashable, Sendable {
    public var seq: Seq
    public var at: Date
    public var projectId: ProjectID?
    /// Команда-источник; у событий от планировщика и демона — `nil`.
    public var commandId: CommandID?
    public var event: JournalEvent

    public init(seq: Seq, at: Date, projectId: ProjectID?, commandId: CommandID? = nil, event: JournalEvent) {
        self.seq = seq; self.at = at; self.projectId = projectId; self.commandId = commandId; self.event = event
    }
}

public enum GitGrantDeliveryVia: String, Codable, Sendable { case mcpResponse = "mcp_response", nextPrompt = "next_prompt" }
public enum GitGrantExpiryReason: String, Codable, Sendable { case taskDone = "task_done", taskCancelled = "task_cancelled" }
public enum Actor: String, Codable, Sendable { case human, agent, daemon, scheduler }

public enum JournalEvent: Hashable, Sendable {
    case taskCreated(TaskCard)
    case taskUpdated(TaskCard)
    /// Переход статуса/стадии с причиной. Карточку целиком несёт следующий `taskUpdated` или этот же payload.
    case taskTransitioned(TaskTransition)
    case taskEdited(TaskCard)
    case projectAdded(ProjectSummary)
    case projectUpdated(ProjectSummary)
    case projectRemoved(ProjectID)
    case pipelineApplied(PipelineSummary)
    case settingsChanged(SettingsChange)
    case humanRequested(HumanRequest)
    case humanAnswered(HumanAnswer)
    case gitDenied(GitDenied)
    case gitGrantCreated(GitGrantCreated)
    case gitGrantDelivered(GitGrantDelivered)
    case gitGrantConsumed(GitGrantRef)
    case gitGrantRevoked(GitGrantRevoked)
    case gitGrantExpired(GitGrantExpired)
    case gitPolicyUpdated(GitPolicyUpdated)
    case incidentOpened(Incident)
    case incidentResolved(IncidentResolved)
    case suspiciousFilesFound(SuspiciousFilesFound)
    case suspiciousFilesAccepted(SuspiciousFilesAccepted)
    /// Загрузка WIP стадии изменилась; шлётся в той же транзакции, что и `taskUpdated` (§3.2, v0.11.2).
    case stageLoadChanged(StageLoad)
    case wipRestored(WIPRestore)
    case cursorEnvironmentChanged(CursorEnvironment)
    /// Событие более новой версии демона. Клиент его пропускает и, если нужно, берёт снимок заново.
    case unknown(type: String)
}

public struct TaskTransition: Codable, Hashable, Sendable {
    public var taskId: TaskID
    public var fromStage: StageID
    public var toStage: StageID
    public var from: TaskState
    public var to: TaskState
    public var by: Actor
    public var runId: RunID?
    public var note: String?
    public init(taskId: TaskID, fromStage: StageID, toStage: StageID, from: TaskState, to: TaskState, by: Actor, runId: RunID? = nil, note: String? = nil) {
        self.taskId = taskId; self.fromStage = fromStage; self.toStage = toStage; self.from = from; self.to = to
        self.by = by; self.runId = runId; self.note = note
    }
}

public struct SettingsChange: Codable, Hashable, Sendable {
    public var key: String
    public var value: String
    /// Authoritative settings after the change. Legacy key/value remains for older clients.
    public var settings: GlobalSettings?
    /// Complete authoritative flag set after a durable scheduler change. nil is legacy/unknown;
    /// an empty array explicitly clears flags. Live ephemeral updates retain their existing DTO.
    public var schedulerFlags: [SchedulerFlag]?
    public init(key: String, value: String, settings: GlobalSettings? = nil, schedulerFlags: [SchedulerFlag]? = nil) {
        self.key = key; self.value = value; self.settings = settings; self.schedulerFlags = schedulerFlags
    }
}

public struct HumanRequest: Codable, Hashable, Sendable {
    public var requestId: HumanRequestID
    public var taskId: TaskID
    public var runId: RunID?
    public var question: String
    public init(requestId: HumanRequestID, taskId: TaskID, runId: RunID?, question: String) {
        self.requestId = requestId; self.taskId = taskId; self.runId = runId; self.question = question
    }
}

public struct HumanAnswer: Codable, Hashable, Sendable {
    public var taskId: TaskID
    public var requestId: HumanRequestID?
    public var text: String
    public init(taskId: TaskID, requestId: HumanRequestID?, text: String) { self.taskId = taskId; self.requestId = requestId; self.text = text }
}

public struct GitDenied: Codable, Hashable, Sendable {
    public var denialId: DenialID; public var taskId: TaskID; public var runId: RunID; public var argv: [String]; public var rule: String
    public init(denialId: DenialID, taskId: TaskID, runId: RunID, argv: [String], rule: String) {
        self.denialId = denialId; self.taskId = taskId; self.runId = runId; self.argv = argv; self.rule = rule
    }
}
public struct GitGrantCreated: Codable, Hashable, Sendable {
    public var grantId: GrantID; public var denialId: DenialID; public var argv: [String]; public var by: Actor
    public init(grantId: GrantID, denialId: DenialID, argv: [String], by: Actor) { self.grantId = grantId; self.denialId = denialId; self.argv = argv; self.by = by }
}
public struct GitGrantDelivered: Codable, Hashable, Sendable {
    public var grantId: GrantID; public var runId: RunID; public var via: GitGrantDeliveryVia
    public init(grantId: GrantID, runId: RunID, via: GitGrantDeliveryVia) { self.grantId = grantId; self.runId = runId; self.via = via }
}
public struct GitGrantRef: Codable, Hashable, Sendable {
    public var grantId: GrantID; public var runId: RunID
    public init(grantId: GrantID, runId: RunID) { self.grantId = grantId; self.runId = runId }
}
public struct GitGrantRevoked: Codable, Hashable, Sendable {
    public var grantId: GrantID; public var by: Actor
    public init(grantId: GrantID, by: Actor) { self.grantId = grantId; self.by = by }
}
public struct GitGrantExpired: Codable, Hashable, Sendable {
    public var grantId: GrantID; public var reason: GitGrantExpiryReason
    public init(grantId: GrantID, reason: GitGrantExpiryReason) { self.grantId = grantId; self.reason = reason }
}
public struct GitPolicyUpdated: Codable, Hashable, Sendable {
    public var projectId: ProjectID; public var scope: PolicyScope; public var pipelineVersion: String
    public init(projectId: ProjectID, scope: PolicyScope, pipelineVersion: String) { self.projectId = projectId; self.scope = scope; self.pipelineVersion = pipelineVersion }
}
public struct IncidentResolved: Codable, Hashable, Sendable {
    public var incidentId: IncidentID; public var by: Actor; public var commandId: CommandID?
    public init(incidentId: IncidentID, by: Actor, commandId: CommandID?) { self.incidentId = incidentId; self.by = by; self.commandId = commandId }
}
public struct SuspiciousFilesFound: Codable, Hashable, Sendable {
    public var taskId: TaskID; public var runId: RunID?; public var stageId: StageID; public var files: [SuspiciousFile]
    public init(taskId: TaskID, runId: RunID?, stageId: StageID, files: [SuspiciousFile]) { self.taskId = taskId; self.runId = runId; self.stageId = stageId; self.files = files }
}
public struct SuspiciousFilesAccepted: Codable, Hashable, Sendable {
    public var taskId: TaskID; public var files: [SuspiciousFile]; public var by: Actor; public var commandId: CommandID?
    public init(taskId: TaskID, files: [SuspiciousFile], by: Actor, commandId: CommandID?) { self.taskId = taskId; self.files = files; self.by = by; self.commandId = commandId }
}

/// Куда добавить отказ в политику (§5 `addDenialToPolicy`).
public enum PolicyScope: Hashable, Sendable, Codable {
    case project
    case stage(StageID)

    enum CodingKeys: String, CodingKey { case kind, stageId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "project": self = .project
        case "stage": self = .stage(try c.decode(StageID.self, forKey: .stageId))
        case let k: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "scope \(k)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project: try c.encode("project", forKey: .kind)
        case .stage(let s): try c.encode("stage", forKey: .kind); try c.encode(s, forKey: .stageId)
        }
    }
}

extension JournalEvent: Codable {
    public var type: String {
        switch self {
        case .taskCreated: "taskCreated"
        case .taskUpdated: "taskUpdated"
        case .taskTransitioned: "taskTransitioned"
        case .taskEdited: "taskEdited"
        case .projectAdded: "projectAdded"
        case .projectUpdated: "projectUpdated"
        case .projectRemoved: "projectRemoved"
        case .pipelineApplied: "pipelineApplied"
        case .settingsChanged: "settingsChanged"
        case .humanRequested: "humanRequested"
        case .humanAnswered: "humanAnswered"
        case .gitDenied: "gitDenied"
        case .gitGrantCreated: "gitGrantCreated"
        case .gitGrantDelivered: "gitGrantDelivered"
        case .gitGrantConsumed: "gitGrantConsumed"
        case .gitGrantRevoked: "gitGrantRevoked"
        case .gitGrantExpired: "gitGrantExpired"
        case .gitPolicyUpdated: "gitPolicyUpdated"
        case .incidentOpened: "incidentOpened"
        case .incidentResolved: "incidentResolved"
        case .suspiciousFilesFound: "suspiciousFilesFound"
        case .suspiciousFilesAccepted: "suspiciousFilesAccepted"
        case .stageLoadChanged: "stageLoadChanged"
        case .wipRestored: "wipRestored"
        case .cursorEnvironmentChanged: "cursorEnvironmentChanged"
        case .unknown(let t): t
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TaggedKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        func d<T: Decodable>(_: T.Type) throws -> T { try c.decode(T.self, forKey: .data) }
        switch type {
        case "taskCreated": self = .taskCreated(try d(TaskCard.self))
        case "taskUpdated": self = .taskUpdated(try d(TaskCard.self))
        case "taskTransitioned": self = .taskTransitioned(try d(TaskTransition.self))
        case "taskEdited": self = .taskEdited(try d(TaskCard.self))
        case "projectAdded": self = .projectAdded(try d(ProjectSummary.self))
        case "projectUpdated": self = .projectUpdated(try d(ProjectSummary.self))
        case "projectRemoved": self = .projectRemoved(try d(ProjectID.self))
        case "pipelineApplied": self = .pipelineApplied(try d(PipelineSummary.self))
        case "settingsChanged": self = .settingsChanged(try d(SettingsChange.self))
        case "humanRequested": self = .humanRequested(try d(HumanRequest.self))
        case "humanAnswered": self = .humanAnswered(try d(HumanAnswer.self))
        case "gitDenied": self = .gitDenied(try d(GitDenied.self))
        case "gitGrantCreated": self = .gitGrantCreated(try d(GitGrantCreated.self))
        case "gitGrantDelivered": self = .gitGrantDelivered(try d(GitGrantDelivered.self))
        case "gitGrantConsumed": self = .gitGrantConsumed(try d(GitGrantRef.self))
        case "gitGrantRevoked": self = .gitGrantRevoked(try d(GitGrantRevoked.self))
        case "gitGrantExpired": self = .gitGrantExpired(try d(GitGrantExpired.self))
        case "gitPolicyUpdated": self = .gitPolicyUpdated(try d(GitPolicyUpdated.self))
        case "incidentOpened": self = .incidentOpened(try d(Incident.self))
        case "incidentResolved": self = .incidentResolved(try d(IncidentResolved.self))
        case "suspiciousFilesFound": self = .suspiciousFilesFound(try d(SuspiciousFilesFound.self))
        case "suspiciousFilesAccepted": self = .suspiciousFilesAccepted(try d(SuspiciousFilesAccepted.self))
        case "stageLoadChanged": self = .stageLoadChanged(try d(StageLoad.self))
        case "wipRestored": self = .wipRestored(try d(WIPRestore.self))
        case "cursorEnvironmentChanged": self = .cursorEnvironmentChanged(try d(CursorEnvironment.self))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TaggedKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .taskCreated(let v), .taskUpdated(let v), .taskEdited(let v): try c.encode(v, forKey: .data)
        case .taskTransitioned(let v): try c.encode(v, forKey: .data)
        case .projectAdded(let v), .projectUpdated(let v): try c.encode(v, forKey: .data)
        case .projectRemoved(let v): try c.encode(v, forKey: .data)
        case .pipelineApplied(let v): try c.encode(v, forKey: .data)
        case .settingsChanged(let v): try c.encode(v, forKey: .data)
        case .humanRequested(let v): try c.encode(v, forKey: .data)
        case .humanAnswered(let v): try c.encode(v, forKey: .data)
        case .gitDenied(let v): try c.encode(v, forKey: .data)
        case .gitGrantCreated(let v): try c.encode(v, forKey: .data)
        case .gitGrantDelivered(let v): try c.encode(v, forKey: .data)
        case .gitGrantConsumed(let v): try c.encode(v, forKey: .data)
        case .gitGrantRevoked(let v): try c.encode(v, forKey: .data)
        case .gitGrantExpired(let v): try c.encode(v, forKey: .data)
        case .gitPolicyUpdated(let v): try c.encode(v, forKey: .data)
        case .incidentOpened(let v): try c.encode(v, forKey: .data)
        case .incidentResolved(let v): try c.encode(v, forKey: .data)
        case .suspiciousFilesFound(let v): try c.encode(v, forKey: .data)
        case .suspiciousFilesAccepted(let v): try c.encode(v, forKey: .data)
        case .stageLoadChanged(let v): try c.encode(v, forKey: .data)
        case .wipRestored(let v): try c.encode(v, forKey: .data)
        case .cursorEnvironmentChanged(let v): try c.encode(v, forKey: .data)
        case .unknown: break
        }
    }
}

// MARK: - Эфемерные события (§5): без `seq`, при переподключении приходят текущим значением в снимке.

public enum EphemeralEvent: Hashable, Sendable {
    case schedulerFlagsChanged([SchedulerFlag])
    case modelFlagsChanged([ModelFlag])
    case quotaUpdated(QuotaState)
    case modelCatalogChanged([ModelInfo])
    case runnerChecked(RunnerCheck)
    case pipelineDraftValidated(PipelineDraftValidation)
    case runProgress(RunProgress)
    case resyncRequired
    case unknown(type: String)
}

public struct RunnerCheck: Codable, Hashable, Sendable {
    public var ok: Bool; public var reason: RunnerUnavailableReason?; public var version: String?; public var checkedAt: Date
    public init(ok: Bool, reason: RunnerUnavailableReason? = nil, version: String? = nil, checkedAt: Date) {
        self.ok = ok; self.reason = reason; self.version = version; self.checkedAt = checkedAt
    }
}
public struct PipelineDraftValidation: Codable, Hashable, Sendable {
    public var projectId: ProjectID; public var contentHash: String; public var issues: [ValidationIssue]
    /// Драфт, разрешённый тем же резолвером, что и `main`: `onFail`/`onConflict`/`gitPolicy` стадий, `defaultReturnStage`,
    /// `projectGitPolicy` для превью в редакторе. `nil`, только если черновик не разобрался как YAML (`yaml_syntax`)
    /// или его корень не mapping; при прочих ошибках поле заполнено (арх. v0.11.10 §3.1).
    public var resolved: PipelineSummary?
    /// Optional for legacy validation events. Version binding travels in the required new draft DTO.
    public var baseVersionHash: String?
    public init(projectId: ProjectID, contentHash: String, issues: [ValidationIssue], resolved: PipelineSummary? = nil,
                baseVersionHash: String? = nil) {
        self.projectId = projectId; self.contentHash = contentHash; self.issues = issues; self.resolved = resolved
        self.baseVersionHash = baseVersionHash
    }
}
public struct RunProgress: Codable, Hashable, Sendable {
    public var runId: RunID; public var taskId: TaskID; public var message: String?; public var lastActivityAt: Date
    public init(runId: RunID, taskId: TaskID, message: String?, lastActivityAt: Date) { self.runId = runId; self.taskId = taskId; self.message = message; self.lastActivityAt = lastActivityAt }
}

extension EphemeralEvent: Codable {
    public var type: String {
        switch self {
        case .schedulerFlagsChanged: "schedulerFlagsChanged"
        case .modelFlagsChanged: "modelFlagsChanged"
        case .quotaUpdated: "quotaUpdated"
        case .modelCatalogChanged: "modelCatalogChanged"
        case .runnerChecked: "runnerChecked"
        case .pipelineDraftValidated: "pipelineDraftValidated"
        case .runProgress: "runProgress"
        case .resyncRequired: "resyncRequired"
        case .unknown(let t): t
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TaggedKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        func d<T: Decodable>(_: T.Type) throws -> T { try c.decode(T.self, forKey: .data) }
        switch type {
        case "schedulerFlagsChanged": self = .schedulerFlagsChanged(try d([SchedulerFlag].self))
        case "modelFlagsChanged": self = .modelFlagsChanged(try d([ModelFlag].self))
        case "quotaUpdated": self = .quotaUpdated(try d(QuotaState.self))
        case "modelCatalogChanged": self = .modelCatalogChanged(try d([ModelInfo].self))
        case "runnerChecked": self = .runnerChecked(try d(RunnerCheck.self))
        case "pipelineDraftValidated": self = .pipelineDraftValidated(try d(PipelineDraftValidation.self))
        case "runProgress": self = .runProgress(try d(RunProgress.self))
        case "resyncRequired": self = .resyncRequired
        default: self = .unknown(type: type)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TaggedKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .schedulerFlagsChanged(let v): try c.encode(v, forKey: .data)
        case .modelFlagsChanged(let v): try c.encode(v, forKey: .data)
        case .quotaUpdated(let v): try c.encode(v, forKey: .data)
        case .modelCatalogChanged(let v): try c.encode(v, forKey: .data)
        case .runnerChecked(let v): try c.encode(v, forKey: .data)
        case .pipelineDraftValidated(let v): try c.encode(v, forKey: .data)
        case .runProgress(let v): try c.encode(v, forKey: .data)
        case .resyncRequired, .unknown: break
        }
    }
}
