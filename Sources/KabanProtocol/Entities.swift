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
    /// Открытые инциденты проекта (значок на скрытых проектах). Обновляется через `projectUpdated`.
    public var openIncidentCount: Int
    /// Автор коммитов демона (§8.2), хранится у демона на этом Маке, не в `.kaban/`. `nil` только у старого демона.
    public var identity: GitIdentity?
    /// Local daemon permissions by server name. `nil` means an older producer did not report them.
    public var mcpAllowlist: [String]?
    public var mcpIssue: McpPreflightIssue?

    public init(id: ProjectID, name: String, path: String, baseBranch: String = "main", availability: Availability = .available,
                weight: Int = 1, maxRuns: Int? = nil, mascotSeed: String, openIncidentCount: Int = 0, identity: GitIdentity? = nil,
                mcpAllowlist: [String]? = nil, mcpIssue: McpPreflightIssue? = nil) {
        self.id = id; self.name = name; self.path = path; self.baseBranch = baseBranch; self.availability = availability
        self.weight = weight; self.maxRuns = maxRuns; self.mascotSeed = mascotSeed; self.openIncidentCount = openIncidentCount
        self.identity = identity
        self.mcpAllowlist = mcpAllowlist; self.mcpIssue = mcpIssue
    }

    enum CodingKeys: String, CodingKey { case id, name, path, baseBranch, availability, weight, maxRuns, mascotSeed, openIncidentCount, identity, mcpAllowlist, mcpIssue }
    /// Поля, добавленные после v1, читаются со значением по умолчанию: старые фикстуры и сценарии остаются валидными.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(ProjectID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  path: try c.decode(String.self, forKey: .path), baseBranch: try c.decode(String.self, forKey: .baseBranch),
                  availability: try c.decode(Availability.self, forKey: .availability), weight: try c.decode(Int.self, forKey: .weight),
                  maxRuns: try c.decodeIfPresent(Int.self, forKey: .maxRuns), mascotSeed: try c.decode(String.self, forKey: .mascotSeed),
                  openIncidentCount: try c.decodeIfPresent(Int.self, forKey: .openIncidentCount) ?? 0,
                  identity: try c.decodeIfPresent(GitIdentity.self, forKey: .identity),
                  mcpAllowlist: try c.decodeIfPresent([String].self, forKey: .mcpAllowlist),
                  mcpIssue: try c.decodeIfPresent(McpPreflightIssue.self, forKey: .mcpIssue))
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
    /// Есть критерии приёмки: без них задачу нельзя отправить из Backlog (спека, UC-01).
    public var hasAcceptanceCriteria: Bool
    public var updatedAt: Date
    /// Durable admission sequence for the current merge queue. nil: source cannot report order.
    public var mergeQueueSequence: Seq?

    public init(id: TaskID, projectId: ProjectID, title: String, stageId: StageID, state: TaskState, priority: Int = 0,
                branch: String? = nil, attempt: Int = 0, maxAttempts: Int? = nil, runsSinceHuman: Int = 0,
                bounceByReason: [String: Int] = [:], overlapsWith: [TaskID] = [], unusedGitGrants: Int = 0,
                model: ModelID? = nil, retryAt: Date? = nil, suspiciousFiles: [SuspiciousFile] = [],
                hasAcceptanceCriteria: Bool = false, updatedAt: Date, mergeQueueSequence: Seq? = nil) {
        self.id = id; self.projectId = projectId; self.title = title; self.stageId = stageId; self.state = state
        self.priority = priority; self.branch = branch; self.attempt = attempt; self.maxAttempts = maxAttempts
        self.runsSinceHuman = runsSinceHuman; self.bounceByReason = bounceByReason; self.overlapsWith = overlapsWith
        self.unusedGitGrants = unusedGitGrants; self.model = model; self.suspiciousFiles = suspiciousFiles; self.retryAt = retryAt
        self.hasAcceptanceCriteria = hasAcceptanceCriteria; self.updatedAt = updatedAt
        self.mergeQueueSequence = mergeQueueSequence
    }

    enum CodingKeys: String, CodingKey {
        case id, projectId, title, stageId, state, priority, branch, attempt, maxAttempts, runsSinceHuman, bounceByReason,
             overlapsWith, unusedGitGrants, model, retryAt, suspiciousFiles, hasAcceptanceCriteria, updatedAt, mergeQueueSequence
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(TaskID.self, forKey: .id), projectId: try c.decode(ProjectID.self, forKey: .projectId),
                  title: try c.decode(String.self, forKey: .title), stageId: try c.decode(StageID.self, forKey: .stageId),
                  state: try c.decode(TaskState.self, forKey: .state), priority: try c.decode(Int.self, forKey: .priority),
                  branch: try c.decodeIfPresent(String.self, forKey: .branch), attempt: try c.decode(Int.self, forKey: .attempt),
                  maxAttempts: try c.decodeIfPresent(Int.self, forKey: .maxAttempts),
                  runsSinceHuman: try c.decode(Int.self, forKey: .runsSinceHuman),
                  bounceByReason: try c.decode([String: Int].self, forKey: .bounceByReason),
                  overlapsWith: try c.decode([TaskID].self, forKey: .overlapsWith),
                  unusedGitGrants: try c.decode(Int.self, forKey: .unusedGitGrants),
                  model: try c.decodeIfPresent(ModelID.self, forKey: .model), retryAt: try c.decodeIfPresent(Date.self, forKey: .retryAt),
                  suspiciousFiles: try c.decode([SuspiciousFile].self, forKey: .suspiciousFiles),
                  hasAcceptanceCriteria: try c.decodeIfPresent(Bool.self, forKey: .hasAcceptanceCriteria) ?? false,
                  updatedAt: try c.decode(Date.self, forKey: .updatedAt),
                  mergeQueueSequence: try c.decodeIfPresent(Seq.self, forKey: .mergeQueueSequence))
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
    /// Текстовый файл по `git diff --numstat` (двоичный даёт `-\t-`). «Дифф» в UI — при `isText` и размере меньше `max_file_mb`.
    public var isText: Bool
    public var blob: String
    public init(path: String, rule: Rule, pattern: String? = nil, sizeBytes: Int64, isText: Bool = false, blob: String) {
        self.path = path; self.rule = rule; self.pattern = pattern; self.sizeBytes = sizeBytes; self.isText = isText; self.blob = blob
    }

    enum CodingKeys: String, CodingKey { case path, rule, pattern, sizeBytes, isText, blob }
    /// Без `isText` (данные до v0.11.2) файл считается двоичным: «дифф» не показываем.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try c.decode(String.self, forKey: .path), rule: try c.decode(Rule.self, forKey: .rule),
                  pattern: try c.decodeIfPresent(String.self, forKey: .pattern), sizeBytes: try c.decode(Int64.self, forKey: .sizeBytes),
                  isText: try c.decodeIfPresent(Bool.self, forKey: .isText) ?? false, blob: try c.decode(String.self, forKey: .blob))
    }
}

public struct IncidentKind: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let refsMoved = Self(rawValue: "refs_moved")
    public static let tagsChanged = Self(rawValue: "tags_changed")
    public static let configChanged = Self(rawValue: "config_changed")
    public static let kabanDirChanged = Self(rawValue: "kaban_dir_changed")
    public static let foreignBase = Self(rawValue: "foreign_base")
    public static let allCases: [Self] = [.refsMoved, .tagsChanged, .configChanged, .kabanDirChanged, .foreignBase]
    public var isKnown: Bool { Self.allCases.contains(self) }
    public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer(); try value.encode(rawValue)
    }
}

public struct IncidentResolution: Codable, Hashable, Sendable {
    public var command: String
    public var target: StageID?
    public var keepBranch: Bool?
    public var commandId: CommandID
    public init(command: String, target: StageID? = nil, keepBranch: Bool? = nil, commandId: CommandID) {
        self.command = command; self.target = target; self.keepBranch = keepBranch; self.commandId = commandId
    }
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
    public var resolution: IncidentResolution?
    public init(id: IncidentID, projectId: ProjectID, taskId: TaskID, runId: RunID?, kind: IncidentKind, rolledBack: [String], openedAt: Date, resolvedAt: Date? = nil, resolution: IncidentResolution? = nil) {
        self.id = id; self.projectId = projectId; self.taskId = taskId; self.runId = runId; self.kind = kind
        self.rolledBack = rolledBack; self.openedAt = openedAt; self.resolvedAt = resolvedAt; self.resolution = resolution
    }
}

/// Состояние доски на момент `seq` (§5 `getSnapshot`).
public struct Snapshot: Codable, Hashable, Sendable {
    /// nil means unavailable from a legacy source; [] is a confirmed empty catalog/rule set.
    public var modelCatalog: [ModelInfo]?
    public var modelPoolRules: [ModelPoolRule]?
    public var protocolVersion: Int
    /// nil means an older server did not supply settings, not product defaults.
    public var settings: GlobalSettings?
    public var seq: Seq
    public var projects: [ProjectSummary]
    public var pipelines: [PipelineSummary]
    public var tasks: [TaskCard]
    public var schedulerFlags: [SchedulerFlag]
    public var modelFlags: [ModelFlag]
    public var quota: QuotaState?
    /// Сумма `ProjectSummary.openIncidentCount` по проектам снимка.
    public var openIncidentCount: Int
    /// Загрузка стадий, считает демон (§3.2); между снимками — `stageLoadChanged`.
    public var stageLoad: [StageLoad]

    public init(seq: Seq, projects: [ProjectSummary], pipelines: [PipelineSummary], tasks: [TaskCard],
                schedulerFlags: [SchedulerFlag] = [], modelFlags: [ModelFlag] = [], quota: QuotaState? = nil, openIncidentCount: Int = 0,
                stageLoad: [StageLoad] = [], settings: GlobalSettings? = nil, modelCatalog: [ModelInfo]? = nil, modelPoolRules: [ModelPoolRule]? = nil) {
        self.protocolVersion = KabanCoding.protocolVersion; self.seq = seq; self.projects = projects; self.pipelines = pipelines
        self.tasks = tasks; self.schedulerFlags = schedulerFlags; self.modelFlags = modelFlags; self.quota = quota
        self.openIncidentCount = openIncidentCount; self.stageLoad = stageLoad; self.settings = settings
        self.modelCatalog = modelCatalog; self.modelPoolRules = modelPoolRules
    }

    enum CodingKeys: String, CodingKey { case protocolVersion, seq, projects, pipelines, tasks, schedulerFlags, modelFlags, quota, openIncidentCount, stageLoad, settings, modelCatalog, modelPoolRules }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(seq: try c.decode(Seq.self, forKey: .seq), projects: try c.decode([ProjectSummary].self, forKey: .projects),
                  pipelines: try c.decode([PipelineSummary].self, forKey: .pipelines), tasks: try c.decode([TaskCard].self, forKey: .tasks),
                  schedulerFlags: try c.decode([SchedulerFlag].self, forKey: .schedulerFlags),
                  modelFlags: try c.decode([ModelFlag].self, forKey: .modelFlags), quota: try c.decodeIfPresent(QuotaState.self, forKey: .quota),
                  openIncidentCount: try c.decode(Int.self, forKey: .openIncidentCount),
                  stageLoad: try c.decodeIfPresent([StageLoad].self, forKey: .stageLoad) ?? [],
                  settings: try c.decodeIfPresent(GlobalSettings.self, forKey: .settings),
                  modelCatalog: try c.decodeIfPresent([ModelInfo].self, forKey: .modelCatalog),
                  modelPoolRules: try c.decodeIfPresent([ModelPoolRule].self, forKey: .modelPoolRules))
        self.protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
    }
}

/// Сколько WIP-слотов стадии занято (§3.2). `wipLimit == nil` — у стадии нет WIP.
public struct StageLoad: Codable, Hashable, Sendable {
    public var projectId: ProjectID
    public var stageId: StageID
    public var wipUsed: Int
    public var wipLimit: Int?
    public init(projectId: ProjectID, stageId: StageID, wipUsed: Int, wipLimit: Int?) {
        self.projectId = projectId; self.stageId = stageId; self.wipUsed = wipUsed; self.wipLimit = wipLimit
    }
}
