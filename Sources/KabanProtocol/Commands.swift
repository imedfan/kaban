import Foundation

/// Команда клиента (§5). Формат на проводе — синтезированный Codable Swift: `{"moveTask": {"taskId": "...", "stage": "..."}}`.
/// Неизвестная демону команда не декодируется, и он отвечает `CommandError.unknownCommand`.
public enum Command: Codable, Hashable, Sendable {
    // Проекты
    /// `identity` — автор коммитов демона (§8.2). Без него демон один раз читает `user.name`/`user.email`
    /// обычным git пользователя в этом репозитории; если автора нет нигде, ответ `identity_required` и проект не создаётся.
    case addProject(path: String, createTemplate: Bool, identity: GitIdentity? = nil)
    /// Сменить автора коммитов демона; действует с новых коммитов. Пустое после обрезки по краям поле
    /// или перенос строки / NUL — `identity_required` (`missing` / `invalid` в `params`), автор не меняется.
    case setProjectIdentity(projectId: ProjectID, identity: GitIdentity)
    case removeProject(projectId: ProjectID)
    case relinkProject(projectId: ProjectID, path: String)
    case listBranches(projectId: ProjectID)
    case detectGates(projectId: ProjectID)
    case setMascot(projectId: ProjectID, seed: String)
    case setProjectWeight(projectId: ProjectID, weight: Int, maxRuns: Int?)
    // Пайплайн и политика
    /// New clients transfer the exact YAML and its base version in `draft`. Hash-only legacy
    /// requests require a server-side draft; they must never apply whichever text happens to exist.
    case updatePipeline(projectId: ProjectID, contentHash: String, draft: PipelineDraft? = nil)
    case validatePipeline(projectId: ProjectID, content: String)
    case validatePipelineDraft(draft: PipelineDraft)
    /// Fresh exact committed and working YAML; does not consume command identity.
    case getPipelineSource(projectId: ProjectID)
    // Детали
    case getTaskDetail(taskId: TaskID)
    // Задачи
    case createTask(projectId: ProjectID, title: String, body: String)
    case editTask(taskId: TaskID, title: String?, body: String?)
    case setPriority(taskId: TaskID, priority: Int)
    case moveTask(taskId: TaskID, stage: StageID)
    case pauseTask(taskId: TaskID)
    case resumeTask(taskId: TaskID)
    case cancelTask(taskId: TaskID, keepBranch: Bool)
    case retryStage(taskId: TaskID, grantAttempts: Int?)
    case setModelOverride(taskId: TaskID, stageId: StageID, model: ModelID?)
    /// The server checks ownership of both run and ref; no arbitrary git ref or path is accepted.
    case restoreWIP(taskId: TaskID, runId: RunID, wipRef: String)
    // Человек
    case answerHuman(taskId: TaskID, text: String, requestId: HumanRequestID?)
    case approve(taskId: TaskID)
    case requestChanges(taskId: TaskID, comments: String, target: StageID?)
    case reject(taskId: TaskID, target: RejectTarget, keepBranch: Bool)
    /// Принять показанный набор подозрительных файлов (§8.2). `files` — ровно тот набор, что видел человек;
    /// если набор успел измениться, демон отвечает `stale_suspicious_files` и ничего не принимает.
    case acceptSuspiciousFiles(taskId: TaskID, files: [FileBlobRef])
    // Git
    case allowGitOnce(denialId: DenialID)
    case addDenialToPolicy(denialId: DenialID, scope: PolicyScope, draft: PipelineDraft? = nil)
    case revokeGitGrant(grantId: GrantID)
    // Планировщик
    case pauseAll
    case resumeAll
    case pauseProject(projectId: ProjectID)
    case resumeProject(projectId: ProjectID)
    case resumeAfterRateLimit
    case setMaxConcurrentRuns(count: Int)
    // Среда
    case checkEnvironment
    case getCursorEnvironment
    case configureCursor(environment: CursorEnvironment)
    case recheck(scope: RecheckScope)
    // Модели и квота
    case listModels
    case refreshModelCatalog
    case setModelPoolRule(pattern: String, pool: ModelPool)
    case removeModelPoolRule(pattern: String)
    case clearModelFlag(modelId: ModelID)
    case setQuotaOptions(options: QuotaOptions)
    // MCP
    case listProjectMcpServers(projectId: ProjectID)
    case setProjectMcpAllowlist(projectId: ProjectID, servers: [McpServerRef])
    // Логи
    case getRunHistory(taskId: TaskID)
    // Инциденты
    case listIncidents(projectIds: [ProjectID]?, state: IncidentListState)
}

/// Файл в конкретной версии: путь + git blob.
public struct FileBlobRef: Codable, Hashable, Sendable {
    public var path: String
    public var blob: String
    public init(path: String, blob: String) { self.path = path; self.blob = blob }
}

/// Принятый человеком подозрительный файл (`task_accepted_file`).
public struct AcceptedFile: Codable, Hashable, Sendable {
    public var path: String
    public var blob: String
    public var by: Actor
    public var at: Date
    public var commandId: CommandID?
    public init(path: String, blob: String, by: Actor = .human, at: Date, commandId: CommandID? = nil) {
        self.path = path; self.blob = blob; self.by = by; self.at = at; self.commandId = commandId
    }
}

public enum RejectTarget: Codable, Hashable, Sendable { case cancel, stage(stageId: StageID) }
public enum RecheckScope: Codable, Hashable, Sendable { case runner, project(projectId: ProjectID) }
public enum IncidentListState: String, Codable, Sendable { case open, all }

public struct QuotaOptions: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var consent: Bool
    /// Интервал опроса в секундах: 60, 300, 900, 1800 или своё.
    public var pollInterval: Int
    public var thresholdCm: Double
    public var thresholdOm: Double
    public init(enabled: Bool, consent: Bool, pollInterval: Int = 300, thresholdCm: Double = 10, thresholdOm: Double = 10) {
        self.enabled = enabled; self.consent = consent; self.pollInterval = pollInterval; self.thresholdCm = thresholdCm; self.thresholdOm = thresholdOm
    }
}

public struct McpServerRef: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case project, personal }
    public var name: String
    public var source: Source
    public init(name: String, source: Source) { self.name = name; self.source = source }
}

/// Конверт запроса: `commandId` генерирует клиент, UI ждёт журнальное событие с тем же `commandId`.
public struct CommandEnvelope: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var commandId: CommandID
    public var command: Command
    public init(commandId: CommandID = CommandID(), command: Command) {
        self.protocolVersion = KabanCoding.protocolVersion; self.commandId = commandId; self.command = command
    }
}

public struct CommandReply: Codable, Hashable, Sendable {
    public var commandId: CommandID
    /// `seq` порождённого журнального события; у чтений — `nil`.
    public var seq: Seq?
    public var result: CommandResult
    public init(commandId: CommandID, seq: Seq?, result: CommandResult) { self.commandId = commandId; self.seq = seq; self.result = result }
}

public enum CommandResult: Codable, Hashable, Sendable {
    case ok
    case pipelineVersion(hash: String)
    case validationIssues([ValidationIssue])
    case branches([String])
    case gates([String])
    case taskCreated(TaskID)
    case environment(EnvironmentReport)
    case models([ModelInfo])
    case mcpServers([McpServerRef])
    case incidents([Incident])
    case runs([RunSummary])
    case taskDetail(TaskDetail)
    case pipelineDraft(PipelineDraftValidation)
    case pipelineSource(PipelineSourceContent)
    case cursorEnvironment(CursorEnvironment)
    case error(CommandError)
}

public struct CommandError: Codable, Hashable, Sendable, Error {
    public var code: String
    public var message: String
    /// Детали ошибки для клиента, как `ValidationIssue.params`; без ключа на проводе — `[:]`.
    /// `identity_required`: `missing` = `name` | `email` | `name,email` (не найдено или пусто после обрезки по краям,
    /// в том числе одни пробелы), `invalid` = `name` | `email` | `name,email` (перенос строки или NUL),
    /// `name`/`email` — найденные корректные значения. Каждое поле ровно в одном из трёх мест; отклонённое значение
    /// не возвращается. В списках порядок всегда `name`, затем `email`.
    public var params: [String: String]
    public init(code: String, message: String, params: [String: String] = [:]) {
        self.code = code; self.message = message; self.params = params
    }
    enum CodingKeys: String, CodingKey { case code, message, params }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(code: try c.decode(String.self, forKey: .code), message: try c.decode(String.self, forKey: .message),
                  params: try c.decodeIfPresent([String: String].self, forKey: .params) ?? [:])
    }

    public static let unknownCommandCode = "unknown_command"
    public static let invalidStateCode = "invalid_state"     // например, `approve` не из `human`-стадии
    public static let notFoundCode = "not_found"
    public static let protocolMismatchCode = "protocol_mismatch"
    public static let staleSuspiciousFilesCode = "stale_suspicious_files"
    /// `addProject` / `setProjectIdentity`: автора нет нигде, имя/почта пустые после обрезки или содержат
    /// перенос строки / NUL; детали в `params` (`missing`, `invalid`, найденные `name`/`email`); ничего не изменено.
    public static let identityRequiredCode = "identity_required"
    public static let unsupportedCommandCode = "unsupported_command"
    public static let unsupportedOperationCode = "unsupported_operation"
    public static let stalePipelineDraftCode = "stale_pipeline_draft"
    public static let pipelineHashMismatchCode = "pipeline_hash_mismatch"
    public static let logUnavailableCode = "log_unavailable"
    public static let logOffsetExpiredCode = "log_offset_expired"
    /// `getTaskDetail` не обрезает сохранённые поля. Клиент запрашивает `getRunHistory` и `readLog`.
    public static let detailTooLargeCode = "detail_too_large"
    /// `getSnapshot` не обрезает карточки. Ответ — ошибка, а не урезанный снимок.
    public static let snapshotTooLargeCode = "snapshot_too_large"
}

/// Автор коммитов демона в проекте (§8.2): передаётся в git явно `-c user.name=… -c user.email=…`.
public struct GitIdentity: Codable, Hashable, Sendable {
    public var name: String
    public var email: String
    public init(name: String, email: String) { self.name = name; self.email = email }
}

public struct EnvironmentReport: Codable, Hashable, Sendable {
    public var cursorAgentPath: String?
    public var version: String?
    public var authOK: Bool
    public var gitVersion: String?
    public var sandboxOK: Bool
    public var notificationsAuthorized: Bool
    public init(cursorAgentPath: String?, version: String?, authOK: Bool, gitVersion: String?, sandboxOK: Bool, notificationsAuthorized: Bool) {
        self.cursorAgentPath = cursorAgentPath; self.version = version; self.authOK = authOK; self.gitVersion = gitVersion
        self.sandboxOK = sandboxOK; self.notificationsAuthorized = notificationsAuthorized
    }
}

/// Всё для панели деталей (§5 `getTaskDetail`).
public struct TaskDetail: Codable, Hashable, Sendable {
    public var seq: Seq
    public var task: TaskCard
    public var feed: [FeedItem]
    public var runs: [RunSummary]
    public var humanRequests: [HumanRequest]
    public var artifacts: [TaskArtifact]
    public var gitGrants: [GitGrantSnapshot]
    public var gitDenials: [GitDenialSnapshot]
    /// Текущий непринятый набор (то же, что `task.suspiciousFiles`), с полными данными правил.
    public var suspiciousFiles: [SuspiciousFile]
    /// Уже принятые по задаче файлы (`task_accepted_file`), для блока «Принято ранее».
    public var acceptedFiles: [AcceptedFile]
    /// Путь клона задачи для «Открыть в Cursor», «дифф» и «Показать в Finder»; `nil`, если клона нет.
    public var clonePath: String?
    /// Markdown task content. nil means unknown legacy content, not an empty body.
    public var body: String?
    /// nil: legacy source cannot report outcomes; []: no restore intents.
    public var wipRestoreOperations: [WIPRestoreOperation]?
    /// Agent stages from this task’s frozen pipeline; nil means an older source cannot report overrides.
    public var modelStages: [TaskModelStage]?
    /// Frozen routes for incident decisions. nil means a legacy producer did not report them.
    public var incidentPipeline: PipelineSummary?
    public init(seq: Seq, task: TaskCard, feed: [FeedItem], runs: [RunSummary], humanRequests: [HumanRequest] = [],
                suspiciousFiles: [SuspiciousFile] = [], acceptedFiles: [AcceptedFile] = [], clonePath: String? = nil,
                artifacts: [TaskArtifact] = [], gitGrants: [GitGrantSnapshot] = [], gitDenials: [GitDenialSnapshot] = [],
                body: String? = nil, wipRestoreOperations: [WIPRestoreOperation]? = nil, modelStages: [TaskModelStage]? = nil, incidentPipeline: PipelineSummary? = nil) {
        self.seq = seq; self.task = task; self.feed = feed; self.runs = runs; self.humanRequests = humanRequests
        self.suspiciousFiles = suspiciousFiles; self.acceptedFiles = acceptedFiles; self.clonePath = clonePath
        self.artifacts = artifacts; self.gitGrants = gitGrants; self.gitDenials = gitDenials
        self.body = body; self.wipRestoreOperations = wipRestoreOperations; self.modelStages = modelStages; self.incidentPipeline = incidentPipeline
    }

    enum CodingKeys: String, CodingKey {
        case seq, task, feed, runs, humanRequests, suspiciousFiles, acceptedFiles, clonePath, artifacts, gitGrants, gitDenials, body, wipRestoreOperations, modelStages, incidentPipeline
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq); try c.encode(task, forKey: .task)
        try c.encode(feed, forKey: .feed); try c.encode(runs, forKey: .runs)
        try c.encode(humanRequests, forKey: .humanRequests)
        try c.encode(suspiciousFiles, forKey: .suspiciousFiles); try c.encode(acceptedFiles, forKey: .acceptedFiles)
        try c.encodeIfPresent(clonePath, forKey: .clonePath)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(wipRestoreOperations, forKey: .wipRestoreOperations)
        try c.encodeIfPresent(modelStages, forKey: .modelStages)
        try c.encodeIfPresent(incidentPipeline, forKey: .incidentPipeline)
        if !artifacts.isEmpty { try c.encode(artifacts, forKey: .artifacts) }
        if !gitGrants.isEmpty { try c.encode(gitGrants, forKey: .gitGrants) }
        if !gitDenials.isEmpty { try c.encode(gitDenials, forKey: .gitDenials) }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(seq: try c.decode(Seq.self, forKey: .seq), task: try c.decode(TaskCard.self, forKey: .task),
                  feed: try c.decode([FeedItem].self, forKey: .feed), runs: try c.decode([RunSummary].self, forKey: .runs),
                  humanRequests: try c.decode([HumanRequest].self, forKey: .humanRequests),
                  suspiciousFiles: try c.decode([SuspiciousFile].self, forKey: .suspiciousFiles),
                  acceptedFiles: try c.decode([AcceptedFile].self, forKey: .acceptedFiles),
                  clonePath: try c.decodeIfPresent(String.self, forKey: .clonePath),
                  artifacts: try c.decodeIfPresent([TaskArtifact].self, forKey: .artifacts) ?? [],
                  gitGrants: try c.decodeIfPresent([GitGrantSnapshot].self, forKey: .gitGrants) ?? [],
                  gitDenials: try c.decodeIfPresent([GitDenialSnapshot].self, forKey: .gitDenials) ?? [],
                  body: try c.decodeIfPresent(String.self, forKey: .body),
                  wipRestoreOperations: try c.decodeIfPresent([WIPRestoreOperation].self, forKey: .wipRestoreOperations),
                  modelStages: try c.decodeIfPresent([TaskModelStage].self, forKey: .modelStages),
                  incidentPipeline: try c.decodeIfPresent(PipelineSummary.self, forKey: .incidentPipeline))
    }
}

/// Строка ленты задачи (`task_feed_item`). `kind` — открытый набор, неизвестный вид клиент рисует как текст.
public struct FeedItem: Codable, Hashable, Sendable {
    public var id: String
    public var at: Date
    public var kind: String   // transition, question, answer, git_denied, git_grant, incident, summary, model_unconfirmed, suspicious_files, ...
    public var text: String
    public var runId: RunID?
    public init(id: String, at: Date, kind: String, text: String, runId: RunID? = nil) {
        self.id = id; self.at = at; self.kind = kind; self.text = text; self.runId = runId
    }
}
