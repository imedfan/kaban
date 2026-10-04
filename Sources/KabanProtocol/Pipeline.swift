import Foundation

public enum StageKind: String, Codable, Sendable, CaseIterable { case queue, agent, gate, human, merge, terminal }

public enum GitPreset: String, Codable, Sendable, CaseIterable { case strict, standard, permissive }

/// Как стадия выглядит на доске (§3.1 `display`).
public struct StageDisplay: Codable, Hashable, Sendable {
    public var icon: String?
    public var color: String?
    public var order: Int
    public var collapsed: Bool
    public var hidden: Bool
    public init(icon: String? = nil, color: String? = nil, order: Int, collapsed: Bool = false, hidden: Bool = false) {
        self.icon = icon; self.color = color; self.order = order; self.collapsed = collapsed; self.hidden = hidden
    }
}

public struct StageReturn: Codable, Hashable, Sendable {
    public var stage: StageID
    public var limit: Int
    public init(stage: StageID, limit: Int) { self.stage = stage; self.limit = limit }
}

/// Стадия в том виде, который нужен доске. Полный YAML читает и валидирует `KabanKit`.
public struct StageSummary: Codable, Hashable, Sendable {
    public var id: StageID
    public var name: String
    public var kind: StageKind
    public var display: StageDisplay
    public var wip: Int?
    /// Обязательна у `agent`; `nil` даёт ошибку валидации и `unavailable: pipeline_invalid`.
    public var model: ModelID?
    public var readOnly: Bool
    public var returnsTo: [StageReturn]
    public var onSuccess: StageID?
    public var maxAttempts: Int?

    public init(id: StageID, name: String, kind: StageKind, display: StageDisplay, wip: Int? = nil, model: ModelID? = nil,
                readOnly: Bool = false, returnsTo: [StageReturn] = [], onSuccess: StageID? = nil, maxAttempts: Int? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.display = display; self.wip = wip; self.model = model
        self.readOnly = readOnly; self.returnsTo = returnsTo; self.onSuccess = onSuccess; self.maxAttempts = maxAttempts
    }
}

public struct PipelineSummary: Codable, Hashable, Sendable {
    public var projectId: ProjectID
    /// Хэш версии из `pipeline_version`; `nil`, если валидной версии в `main` нет.
    public var versionHash: String?
    public var gitPreset: GitPreset
    public var maxWaitingHuman: Int
    public var maxRunsPerTask: Int
    public var stages: [StageSummary]
    /// Ошибки и предупреждения текущей версии в `main`.
    public var issues: [ValidationIssue]
    /// Есть незакоммиченная ручная правка `.kaban/` (§3.1, FSEvents).
    public var hasUncommittedEdits: Bool

    public init(projectId: ProjectID, versionHash: String?, gitPreset: GitPreset = .standard, maxWaitingHuman: Int = 3,
                maxRunsPerTask: Int = 12, stages: [StageSummary], issues: [ValidationIssue] = [], hasUncommittedEdits: Bool = false) {
        self.projectId = projectId; self.versionHash = versionHash; self.gitPreset = gitPreset; self.maxWaitingHuman = maxWaitingHuman
        self.maxRunsPerTask = maxRunsPerTask; self.stages = stages; self.issues = issues; self.hasUncommittedEdits = hasUncommittedEdits
    }

    public var isValid: Bool { !issues.contains { $0.severity == .error } }
}

/// Ошибка или предупреждение валидации (§3.1). `path` — путь к полю для подсветки, например `stages[2].wip`.
public struct ValidationIssue: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var path: String
    public var code: String
    public var message: String
    public var severity: Severity
    public init(path: String, code: String, message: String, severity: Severity) {
        self.path = path; self.code = code; self.message = message; self.severity = severity
    }
}

/// Известные коды валидации, общие для демона и редактора.
public enum ValidationCode {
    public static let modelMissing = "model_missing"
    public static let modelAutoForbidden = "model_auto_forbidden"
    public static let mcpNotAllowlisted = "mcp_not_allowlisted"   // предупреждение, не ошибка
    public static let backoffTooLong = "backoff_too_long"
    public static let stageHasActiveTasks = "stage_has_active_tasks"
    public static let terminalUnreachable = "terminal_unreachable"
    public static let returnsForward = "returns_forward"
    public static let wipOutOfRange = "wip_out_of_range"
    public static let secretInEnv = "secret_in_env"
}
