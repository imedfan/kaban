import Foundation

public struct ProjectSummary: Codable, Hashable, Sendable {
    public enum Availability: String, Codable, Sendable { case available, missing }
    public var id: ProjectID
    public var name: String
    public var path: String
    public var baseBranch: String
    public var availability: Availability
    public var weight: Int
    public var maxRuns: Int?
    public var mascotSeed: String

    public init(id: ProjectID, name: String, path: String, baseBranch: String = "main", availability: Availability = .available,
                weight: Int = 1, maxRuns: Int? = nil, mascotSeed: String) {
        self.id = id; self.name = name; self.path = path; self.baseBranch = baseBranch; self.availability = availability
        self.weight = weight; self.maxRuns = maxRuns; self.mascotSeed = mascotSeed
    }
}

/// Карточка задачи на доске (без ленты; лента — в `TaskDetail`).
public struct TaskCard: Codable, Hashable, Sendable {
    public var id: TaskID
    public var projectId: ProjectID
    public var title: String
    public var stageId: StageID
    public var state: TaskState
    public var priority: Int
    public var branch: String?
    /// Номер попытки в текущем заходе в стадию и лимит (`2/3`).
    public var attempt: Int
    public var maxAttempts: Int?
    /// Автоматические runs с последнего действия человека и лимит `max_runs_per_task`.
    public var runsSinceHuman: Int
    public var bounceByReason: [String: Int]
    public var overlapsWith: [TaskID]
    public var unusedGitGrants: Int
    public var model: ModelID?
    public var retryAt: Date?
    /// Текущий непринятый набор подозрительных файлов; не пуст только в `waiting_human: suspicious_files` (§8.2).
    /// Приходит в снимке и в `taskUpdated`, поэтому переживает перезапуск и `resyncRequired`.
    public var suspiciousFiles: [SuspiciousFile]
    public var updatedAt: Date

    public init(id: TaskID, projectId: ProjectID, title: String, stageId: StageID, state: TaskState, priority: Int = 0,
                branch: String? = nil, attempt: Int = 0, maxAttempts: Int? = nil, runsSinceHuman: Int = 0,
                bounceByReason: [String: Int] = [:], overlapsWith: [TaskID] = [], unusedGitGrants: Int = 0,
                model: ModelID? = nil, retryAt: Date? = nil, suspiciousFiles: [SuspiciousFile] = [], updatedAt: Date) {
        self.id = id; self.projectId = projectId; self.title = title; self.stageId = stageId; self.state = state
        self.priority = priority; self.branch = branch; self.attempt = attempt; self.maxAttempts = maxAttempts
        self.runsSinceHuman = runsSinceHuman; self.bounceByReason = bounceByReason; self.overlapsWith = overlapsWith
        self.unusedGitGrants = unusedGitGrants; self.model = model; self.suspiciousFiles = suspiciousFiles; self.retryAt = retryAt; self.updatedAt = updatedAt
    }
}

public struct RunSummary: Codable, Hashable, Sendable {
    public var id: RunID
    public var taskId: TaskID
    public var stageId: StageID
    public var number: Int
    public var status: RunStatus
    public var endReason: RunEndReason?
    public var requestedModel: ModelID
    /// Отображаемое имя из `system/init`; `nil`, пока не пришло.
    public var actualModelName: String?
    public var countsTowardLimits: Bool
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var logPath: String?
    public var wipRef: String?   // refs/kaban/wip/<run-id>, если клон откатывали

    public init(id: RunID, taskId: TaskID, stageId: StageID, number: Int, status: RunStatus, endReason: RunEndReason? = nil,
                requestedModel: ModelID, actualModelName: String? = nil, countsTowardLimits: Bool = true, startedAt: Date,
                endedAt: Date? = nil, exitCode: Int32? = nil, logPath: String? = nil, wipRef: String? = nil) {
        self.id = id; self.taskId = taskId; self.stageId = stageId; self.number = number; self.status = status
        self.endReason = endReason; self.requestedModel = requestedModel; self.actualModelName = actualModelName
        self.countsTowardLimits = countsTowardLimits; self.startedAt = startedAt; self.endedAt = endedAt
        self.exitCode = exitCode; self.logPath = logPath; self.wipRef = wipRef
    }
}

public struct SuspiciousFile: Codable, Hashable, Sendable {
    public enum Rule: String, Codable, Sendable { case pattern, size }
    public var path: String
    public var rule: Rule
    public var pattern: String?
    public var sizeBytes: Int64
    public var blob: String
    public init(path: String, rule: Rule, pattern: String? = nil, sizeBytes: Int64, blob: String) {
        self.path = path; self.rule = rule; self.pattern = pattern; self.sizeBytes = sizeBytes; self.blob = blob
    }
}

public enum IncidentKind: String, Codable, Sendable, CaseIterable {
    case refsMoved = "refs_moved"
    case tagsChanged = "tags_changed"
    case configChanged = "config_changed"
    case kabanDirChanged = "kaban_dir_changed"
    case foreignBase = "foreign_base"
}

public struct Incident: Codable, Hashable, Sendable {
    public var id: IncidentID
    public var projectId: ProjectID
    public var taskId: TaskID
    public var runId: RunID?
    public var kind: IncidentKind
    public var rolledBack: [String]
    public var openedAt: Date
    public var resolvedAt: Date?
    public init(id: IncidentID, projectId: ProjectID, taskId: TaskID, runId: RunID?, kind: IncidentKind, rolledBack: [String], openedAt: Date, resolvedAt: Date? = nil) {
        self.id = id; self.projectId = projectId; self.taskId = taskId; self.runId = runId; self.kind = kind
        self.rolledBack = rolledBack; self.openedAt = openedAt; self.resolvedAt = resolvedAt
    }
}

/// Состояние доски на момент `seq` (§5 `getSnapshot`).
public struct Snapshot: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var seq: Seq
    public var projects: [ProjectSummary]
    public var pipelines: [PipelineSummary]
    public var tasks: [TaskCard]
    public var schedulerFlags: [SchedulerFlag]
    public var modelFlags: [ModelFlag]
    public var quota: QuotaState?
    public var openIncidentCount: Int

    public init(seq: Seq, projects: [ProjectSummary], pipelines: [PipelineSummary], tasks: [TaskCard],
                schedulerFlags: [SchedulerFlag] = [], modelFlags: [ModelFlag] = [], quota: QuotaState? = nil, openIncidentCount: Int = 0) {
        self.protocolVersion = KabanCoding.protocolVersion; self.seq = seq; self.projects = projects; self.pipelines = pipelines
        self.tasks = tasks; self.schedulerFlags = schedulerFlags; self.modelFlags = modelFlags; self.quota = quota
        self.openIncidentCount = openIncidentCount
    }
}
