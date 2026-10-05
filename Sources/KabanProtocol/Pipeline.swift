import Foundation

public enum StageKind: String, Codable, Sendable, CaseIterable { case queue, agent, gate, human, merge, terminal }

public enum GitPreset: String, Codable, Hashable, Sendable, CaseIterable { case strict, standard, permissive }

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
    /// Гейт-команды стадии (`gates`), в том числе у `agent`-стадий без своей колонки гейтов.
    public var gates: [String]
    /// Возврат `gate`-стадии при красных гейтах; приходит уже разрешённым: по умолчанию ближайшая предыдущая по `on_success`
    /// `agent`-стадия с `readOnly = false`, `limit = 3`. Для `gate` демон заполняет всегда (арх. v0.11.5 §3.1).
    public var onFail: StageReturn?
    /// Возврат `merge`-стадии при конфликте rebase; приходит разрешённым: по умолчанию первая `agent`-стадия
    /// с `readOnly = false`, `limit = 2`. Для `merge` демон заполняет всегда.
    public var onConflict: StageReturn?
    /// Эффективная git-политика стадии, посчитанная демоном (арх. v0.11.6 §8.4). Заполнена у `agent`-стадий, у остальных `nil`.
    public var gitPolicy: EffectiveGitPolicy?

    public init(id: StageID, name: String, kind: StageKind, display: StageDisplay, wip: Int? = nil, model: ModelID? = nil,
                readOnly: Bool = false, returnsTo: [StageReturn] = [], onSuccess: StageID? = nil, maxAttempts: Int? = nil,
                gates: [String] = [], onFail: StageReturn? = nil, onConflict: StageReturn? = nil, gitPolicy: EffectiveGitPolicy? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.display = display; self.wip = wip; self.model = model
        self.readOnly = readOnly; self.returnsTo = returnsTo; self.onSuccess = onSuccess; self.maxAttempts = maxAttempts
        self.gates = gates; self.onFail = onFail; self.onConflict = onConflict; self.gitPolicy = gitPolicy
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, display, wip, model, readOnly, returnsTo, onSuccess, maxAttempts, gates, onFail, onConflict, gitPolicy }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(StageID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  kind: try c.decode(StageKind.self, forKey: .kind), display: try c.decode(StageDisplay.self, forKey: .display),
                  wip: try c.decodeIfPresent(Int.self, forKey: .wip), model: try c.decodeIfPresent(ModelID.self, forKey: .model),
                  readOnly: try c.decode(Bool.self, forKey: .readOnly), returnsTo: try c.decode([StageReturn].self, forKey: .returnsTo),
                  onSuccess: try c.decodeIfPresent(StageID.self, forKey: .onSuccess),
                  maxAttempts: try c.decodeIfPresent(Int.self, forKey: .maxAttempts),
                  gates: try c.decodeIfPresent([String].self, forKey: .gates) ?? [],
                  onFail: try c.decodeIfPresent(StageReturn.self, forKey: .onFail),
                  onConflict: try c.decodeIfPresent(StageReturn.self, forKey: .onConflict),
                  gitPolicy: try c.decodeIfPresent(EffectiveGitPolicy.self, forKey: .gitPolicy))
    }
}

/// Кто делает коммиты стадии (§6.3).
public enum StageCommitter: String, Codable, Hashable, Sendable, CaseIterable {
    /// `strict`: агент не коммитит; демон делает один коммит из `complete_stage.summary` после зелёных гейтов.
    case daemonOnly = "daemon_only"
    /// `standard` / `permissive`: коммитит агент, демон добавляет страховочный коммит `kaban: <stage> <task>`.
    case agentWithSafetyCommit = "agent_with_safety_commit"
}

/// Из какого слоя пришло правило итоговой политики (арх. v0.11.9 §8.4): последний слой (пресет → проект → стадия),
/// который изменил итог правила; повтор того же решения слой не меняет. Запрет на любом слое сильнее разрешения.
public enum GitRuleSource: String, Codable, Hashable, Sendable, CaseIterable {
    case preset
    /// `allow` / `deny` проекта.
    case project
    /// `extend` / `deny` стадии: «переопределено» или «сужено».
    case stage
}

/// Правило политики: нормализованная подкоманда (`status`, `restore --staged`, `rebase`) и слой, откуда оно пришло.
/// Сопоставление по префиксу слов (арх. v0.11.10 §8.4): правило `restore` покрывает `restore --staged`, но не наоборот.
/// Запрет сильнее разрешения, поэтому разрешённое правило, покрытое любым `denied`, в `allowed` не попадает.
public struct GitRule: Codable, Hashable, Sendable {
    public var rule: String
    /// `nil` — слой неизвестен (значение от более нового демона); UI показывает правило без пометки.
    public var source: GitRuleSource?
    public init(_ rule: String, source: GitRuleSource?) { self.rule = rule; self.source = source }

    enum CodingKeys: String, CodingKey { case rule, source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(String.self, forKey: .rule),
                  source: (try c.decodeIfPresent(String.self, forKey: .source)).flatMap(GitRuleSource.init(rawValue:)))
    }
}

/// Итоговая git-политика стадии: пресет → allow/deny проекта → оверрайды стадии (арх. v0.11.8 §8.4).
/// Считает только демон (`GitPolicyResolver` в `KabanKit`); клиент показывает как есть и ничего не вычисляет.
/// Разовые `git_grant` сюда не входят, они показаны в панели задачи.
public struct EffectiveGitPolicy: Codable, Hashable, Sendable {
    public var preset: GitPreset
    /// Разрешено всегда (без условных правил).
    public var allowed: [GitRule]
    public var denied: [GitRule]
    /// Жёсткие инварианты (id из `HardInvariant`): никакой пресет или оверрайд их не снимает. Шаблоны проверки живут в `KabanKit`.
    public var hardInvariants: [String]
    /// `extend` с условием `when: return_reason == …`: добавляются к `allowed`, только когда задача вернулась с этой причиной.
    public var conditional: [ConditionalGitRule]
    public var committer: StageCommitter
    public var readOnly: Bool

    public init(preset: GitPreset, allowed: [GitRule], denied: [GitRule] = [], hardInvariants: [String], conditional: [ConditionalGitRule] = [],
                committer: StageCommitter, readOnly: Bool) {
        self.preset = preset; self.allowed = allowed; self.denied = denied; self.hardInvariants = hardInvariants
        self.conditional = conditional; self.committer = committer; self.readOnly = readOnly
    }

    enum CodingKeys: String, CodingKey { case preset, allowed, denied, hardInvariants, conditional, committer, readOnly }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(preset: try c.decode(GitPreset.self, forKey: .preset), allowed: try c.decode([GitRule].self, forKey: .allowed),
                  denied: try c.decodeIfPresent([GitRule].self, forKey: .denied) ?? [],
                  hardInvariants: try c.decodeIfPresent([String].self, forKey: .hardInvariants) ?? [],
                  conditional: try c.decodeIfPresent([ConditionalGitRule].self, forKey: .conditional) ?? [],
                  committer: try c.decode(StageCommitter.self, forKey: .committer), readOnly: try c.decode(Bool.self, forKey: .readOnly))
    }
}

/// Id жёстких инвариантов (арх. v0.11.12 §8.2). `all` — канонический порядок показа, как в спеке §1.5; демон отдаёт `hardInvariants` в этом порядке. Набор открытый: неизвестный id UI показывает как есть, с замком.
public enum HardInvariant {
    /// `push` в любом виде.
    public static let push = "push"
    public static let remote = "remote"
    public static let config = "config"
    public static let tag = "tag"
    /// `--force` на любой команде; короткий `-f` (в том числе в связках вроде `-fd`) — только там, где он принудительный: `checkout`, `switch`, `add`, `rm`, `mv`, `clean`, `worktree`, `submodule`.
    public static let force = "force"
    /// Любые refs вне ветки задачи: `main`, чужие ветки, `update-ref`, `symbolic-ref`, `branch -d/-D/-f/-m/-M/-C`, `checkout -B`, `switch -C`, `filter-branch`, `reflog expire`.
    public static let foreignRefs = "foreign_refs"
    /// Запись в `.kaban/`; не git-команда, держат `/git/check` и Seatbelt, здесь — для показа.
    public static let kabanDir = "kaban_dir"
    public static let all = [push, remote, config, tag, force, foreignRefs, kabanDir]
}

/// Условное расширение политики стадии. `returnReason` — сырое значение (`merge_conflict`, `returned`, …), неизвестное UI показывает как есть.
public struct ConditionalGitRule: Codable, Hashable, Sendable {
    public var returnReason: String
    /// Всегда `source = stage`: `when` бывает только у стадии. Правила, запрещённые `deny`, сюда не попадают.
    public var allowed: [GitRule]
    public init(returnReason: String, allowed: [GitRule]) { self.returnReason = returnReason; self.allowed = allowed }
}

public struct PipelineSummary: Codable, Hashable, Sendable {
    public var projectId: ProjectID
    /// Хэш версии из `pipeline_version`; `nil`, если валидной версии в `main` нет.
    public var versionHash: String?
    /// Identity of the committed .kaban assets, even when YAML is missing/invalid. nil from
    /// older daemons. Drafts use it to distinguish successive invalid versions safely.
    public var sourceHash: String?
    public var gitPreset: GitPreset
    public var maxWaitingHuman: Int
    public var maxRunsPerTask: Int
    public var stages: [StageSummary]
    /// Ошибки и предупреждения текущей версии в `main`.
    public var issues: [ValidationIssue]
    /// Есть незакоммиченная ручная правка `.kaban/` (§3.1, FSEvents).
    public var hasUncommittedEdits: Bool
    /// Validation of the observed working YAML, separate from committed issues. nil means
    /// no dirty draft was observed (or a legacy daemon); errors here do not stop current main.
    public var uncommittedIssues: [ValidationIssue]?
    /// Куда по умолчанию ведёт `requestChanges` без `target`: первая `agent`-стадия с `readOnly = false`,
    /// разрешённая демоном; `nil` — такой стадии нет (арх. v0.11.5 §3.1).
    public var defaultReturnStage: StageID?
    /// Политика уровня проекта: пресет → `allow`/`deny` проекта, без стадий (`source` только `preset` или `project`).
    /// Колонка «Политика проекта» в редакторе стадии (арх. v0.11.10 §8.4). `nil` от старого демона.
    public var projectGitPolicy: EffectiveGitPolicy?
    /// Каталог известных git-команд (первые слова), по нему валидатор выдаёт `git_unknown_command`.
    /// «Нет в пресете» = команда из каталога, которой нет ни в `allowed`, ни в `denied`.
    public var gitCommandCatalog: [String]

    public init(projectId: ProjectID, versionHash: String?, gitPreset: GitPreset = .standard, maxWaitingHuman: Int = 3,
                maxRunsPerTask: Int = 12, stages: [StageSummary], issues: [ValidationIssue] = [], hasUncommittedEdits: Bool = false,
                defaultReturnStage: StageID? = nil, projectGitPolicy: EffectiveGitPolicy? = nil, gitCommandCatalog: [String] = [], sourceHash: String? = nil, uncommittedIssues: [ValidationIssue]? = nil) {
        self.projectId = projectId; self.versionHash = versionHash; self.gitPreset = gitPreset; self.maxWaitingHuman = maxWaitingHuman
        self.sourceHash = sourceHash
        self.uncommittedIssues = uncommittedIssues
        self.maxRunsPerTask = maxRunsPerTask; self.stages = stages; self.issues = issues; self.hasUncommittedEdits = hasUncommittedEdits
        self.defaultReturnStage = defaultReturnStage; self.projectGitPolicy = projectGitPolicy; self.gitCommandCatalog = gitCommandCatalog
    }

    enum CodingKeys: String, CodingKey {
        case projectId, versionHash, gitPreset, maxWaitingHuman, maxRunsPerTask, stages, issues, hasUncommittedEdits, defaultReturnStage
        case projectGitPolicy, gitCommandCatalog, sourceHash, uncommittedIssues
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(projectId: try c.decode(ProjectID.self, forKey: .projectId), versionHash: try c.decodeIfPresent(String.self, forKey: .versionHash),
                  gitPreset: try c.decode(GitPreset.self, forKey: .gitPreset), maxWaitingHuman: try c.decode(Int.self, forKey: .maxWaitingHuman),
                  maxRunsPerTask: try c.decode(Int.self, forKey: .maxRunsPerTask), stages: try c.decode([StageSummary].self, forKey: .stages),
                  issues: try c.decode([ValidationIssue].self, forKey: .issues), hasUncommittedEdits: try c.decode(Bool.self, forKey: .hasUncommittedEdits),
                  defaultReturnStage: try c.decodeIfPresent(StageID.self, forKey: .defaultReturnStage),
                  projectGitPolicy: try c.decodeIfPresent(EffectiveGitPolicy.self, forKey: .projectGitPolicy),
                  gitCommandCatalog: try c.decodeIfPresent([String].self, forKey: .gitCommandCatalog) ?? [],
                  sourceHash: try c.decodeIfPresent(String.self, forKey: .sourceHash),
                  uncommittedIssues: try c.decodeIfPresent([ValidationIssue].self, forKey: .uncommittedIssues))
    }

    public var isValid: Bool { !issues.contains { $0.severity == .error } }
}

/// Ошибка или предупреждение валидации (§3.1). `path` — путь к полю для подсветки, например `stages[2].wip`.
public struct ValidationIssue: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var path: String
    /// Стадия, к которой относится ошибка, для подсветки в редакторе; `nil` — ошибка уровня пайплайна.
    public var stageId: StageID?
    public var code: String
    /// Готовый текст от демона; запасной вариант, если у UI нет перевода кода.
    public var message: String
    public var severity: Severity
    /// Подстановки для текста кода из словаря спеки §4.1 (`line`, `n`, `min`, `max`, …). Значения — строки как есть;
    /// пустой словарь, если подстановок нет или их прислал старый демон (арх. v0.11.7).
    public var params: [String: String]
    public init(path: String, stageId: StageID? = nil, code: String, message: String, severity: Severity, params: [String: String] = [:]) {
        self.path = path; self.stageId = stageId; self.code = code; self.message = message; self.severity = severity; self.params = params
    }

    enum CodingKeys: String, CodingKey { case path, stageId, code, message, severity, params }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try c.decode(String.self, forKey: .path), stageId: try c.decodeIfPresent(StageID.self, forKey: .stageId),
                  code: try c.decode(String.self, forKey: .code), message: try c.decode(String.self, forKey: .message),
                  severity: try c.decode(Severity.self, forKey: .severity),
                  params: try c.decodeIfPresent([String: String].self, forKey: .params) ?? [:])
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
    public static let yamlSyntax = "yaml_syntax"
    public static let duplicateId = "duplicate_id"
    public static let unknownStage = "unknown_stage"
    public static let onSuccessCycle = "on_success_cycle"
    public static let gitHardInvariant = "git_hard_invariant"
    /// У возврата нет допустимой цели или явная цель read-only; `stageId` — стадия с этим возвратом (арх. v0.11.5 §3.1).
    public static let noReturnTarget = "no_return_target"
    // Коды валидатора KabanKit, до v0.11.4 жившие в `KabanValidationCode` (арх. v0.11.4 §3.1: коды только здесь).
    public static let typeMismatch = "type_mismatch"
    public static let missingField = "missing_field"
    public static let unknownKey = "unknown_key"   // предупреждение
    public static let invalidValue = "invalid_value"
    public static let versionUnsupported = "version_unsupported"
    public static let noStages = "no_stages"
    public static let invalidId = "invalid_id"
    public static let queueCount = "queue_count"
    public static let mergeCount = "merge_count"
    public static let terminalMissing = "terminal_missing"
    public static let onSuccessMissing = "on_success_missing"
    public static let terminalHasOnSuccess = "terminal_has_on_success"
    public static let fieldNotAllowedForKind = "field_not_allowed_for_kind"
    public static let returnsNotAllowed = "returns_not_allowed"
    public static let agentMissing = "agent_missing"
    public static let harnessUnsupported = "harness_unsupported"
    public static let limitOutOfRange = "limit_out_of_range"
    public static let durationOutOfRange = "duration_out_of_range"
    public static let attemptsOutOfRange = "attempts_out_of_range"
    public static let gitConditionInvalid = "git_condition_invalid"
    public static let gitUnknownCommand = "git_unknown_command"   // предупреждение
    /// Read-only стадия разрешает (`extend`, в том числе с `when`) пишущую команду. Ошибка, `params["cmd"]` — первое слово правила (арх. v0.11.18 §8.4).
    public static let gitReadonlyExtend = "git_readonly_extend"
}
