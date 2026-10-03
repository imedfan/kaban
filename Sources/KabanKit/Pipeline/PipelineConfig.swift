import Foundation
import KabanProtocol

/// Full, typed `.kaban/pipeline.yaml` (architecture §3.1). Codable so a valid version can be stored
/// as a JSON snapshot in `pipeline_version`. Board-facing projections come from `KabanProtocol`
/// (`PipelineSummary`, `StageSummary`), see `PipelineConfig.summary(...)`.
public struct PipelineConfig: Codable, Hashable, Sendable {
    public var version: Int
    public var board: BoardSettings
    public var workspace: WorkspaceSettings
    public var git: ProjectGitPolicy
    public var suspiciousFiles: SuspiciousFilesPolicy
    public var stages: [StageConfig]

    public init(version: Int = 1, board: BoardSettings = .init(), workspace: WorkspaceSettings = .init(),
                git: ProjectGitPolicy = .init(), suspiciousFiles: SuspiciousFilesPolicy = .init(), stages: [StageConfig]) {
        self.version = version; self.board = board; self.workspace = workspace; self.git = git
        self.suspiciousFiles = suspiciousFiles; self.stages = stages
    }

    public func stage(_ id: StageID) -> StageConfig? { stages.first { $0.id == id } }
    public func index(of id: StageID) -> Int? { stages.firstIndex { $0.id == id } }

    /// The single `queue` stage (Backlog), entry point of the pipeline.
    public var entryStage: StageConfig? { stages.first { $0.kind == .queue } }
    public var mergeStage: StageConfig? { stages.first { $0.kind == .merge } }

    /// First `agent` stage along the `on_success` chain from the entry stage (default target of
    /// `requestChanges` and merge conflicts, §3.3, §8.5).
    public var firstAgentStage: StageConfig? {
        successChain(from: entryStage?.id).lazy.compactMap { self.stage($0) }.first { $0.kind == .agent }
            ?? stages.first { $0.kind == .agent }
    }

    /// Stage ids visited by following `on_success` from `start` (inclusive), stopping on a cycle or dangling reference.
    public func successChain(from start: StageID?) -> [StageID] {
        var out: [StageID] = []
        var seen = Set<StageID>()
        var cursor = start
        while let id = cursor, let s = stage(id), seen.insert(id).inserted {
            out.append(id)
            cursor = s.onSuccess
        }
        return out
    }

    /// `true` when `upstream` reaches `downstream` by `on_success` (i.e. `upstream` is earlier in the chain).
    public func isUpstream(_ upstream: StageID, of downstream: StageID) -> Bool {
        upstream != downstream && successChain(from: upstream).contains(downstream)
    }
}

public struct BoardSettings: Codable, Hashable, Sendable {
    public static let defaultMaxWaitingHuman = 3
    public static let defaultBounceLimitTotal = 5
    /// Decisions log 2026-10-03: automatic runs only; human actions reset the counter.
    public static let defaultMaxRunsPerTask = 12

    public var maxWaitingHuman: Int
    public var bounceLimitTotal: Int
    public var maxRunsPerTask: Int

    public init(maxWaitingHuman: Int = defaultMaxWaitingHuman, bounceLimitTotal: Int = defaultBounceLimitTotal,
                maxRunsPerTask: Int = defaultMaxRunsPerTask) {
        self.maxWaitingHuman = maxWaitingHuman; self.bounceLimitTotal = bounceLimitTotal; self.maxRunsPerTask = maxRunsPerTask
    }
}

public struct WorkspaceSettings: Codable, Hashable, Sendable {
    public var warmPaths: [String]
    public var onCreate: String?
    public init(warmPaths: [String] = [], onCreate: String? = nil) { self.warmPaths = warmPaths; self.onCreate = onCreate }
}

/// Project-level git policy (§8.4). Stages only carry overrides (`StageGitOverride`).
public struct ProjectGitPolicy: Codable, Hashable, Sendable {
    public var preset: GitPreset
    public var allow: [String]
    public var deny: [String]
    public init(preset: GitPreset = .standard, allow: [String] = [], deny: [String] = []) {
        self.preset = preset; self.allow = allow; self.deny = deny
    }
}

/// `suspicious_files` (§8.2, UC-25).
public struct SuspiciousFilesPolicy: Codable, Hashable, Sendable {
    public static let defaultPatterns = [".env*", "*.pem", "*.key", "*.p12", "id_rsa*", "id_ed25519*"]
    public static let defaultAllow = [".env.example"]
    public static let defaultMaxFileMB: Double = 5

    public var patterns: [String]
    public var maxFileMB: Double
    public var allow: [String]
    public init(patterns: [String] = defaultPatterns, maxFileMB: Double = defaultMaxFileMB, allow: [String] = defaultAllow) {
        self.patterns = patterns; self.maxFileMB = maxFileMB; self.allow = allow
    }
    public var maxFileBytes: Int64 { Int64(maxFileMB * 1024 * 1024) }
}

/// Order of picking queued tasks inside a stage (`priority: [returned, answered, fifo]`).
public enum PriorityRule: String, Codable, Hashable, Sendable, CaseIterable { case returned, answered, fifo }

public struct StageConfig: Codable, Hashable, Sendable {
    public static let defaultPriority: [PriorityRule] = [.returned, .answered, .fifo]

    public var id: StageID
    public var name: String
    public var kind: StageKind
    public var display: StageDisplay
    /// `nil`: no limit for `human`, 1 for `agent`/`gate` (see `effectiveWIP`), always 1 for `merge`.
    public var wip: Int?
    public var priority: [PriorityRule]
    public var agent: AgentConfig?
    public var git: StageGitOverride?
    public var inputs: [String]
    public var gates: [String]
    public var onSuccess: StageID?
    public var returnsTo: [StageReturn]
    /// `gate` stages: where a red gate sends the task (counts as an automatic return). `nil` — retry in place.
    public var onFail: StageReturn?
    /// `merge` stage: where a rebase conflict / red post-rebase gates send the task. Defaults resolved by `conflictReturn(in:)`.
    public var onConflict: ConflictReturn?
    public var retry: RetryPolicy
    public var timeouts: StageTimeouts
    public var hooks: StageHooks
    public var notify: [String]

    public init(id: StageID, name: String? = nil, kind: StageKind, display: StageDisplay? = nil, wip: Int? = nil,
                priority: [PriorityRule] = StageConfig.defaultPriority, agent: AgentConfig? = nil, git: StageGitOverride? = nil,
                inputs: [String] = [], gates: [String] = [], onSuccess: StageID? = nil, returnsTo: [StageReturn] = [],
                onFail: StageReturn? = nil, onConflict: ConflictReturn? = nil, retry: RetryPolicy = .init(),
                timeouts: StageTimeouts = .init(), hooks: StageHooks = .init(), notify: [String] = []) {
        self.id = id; self.name = name ?? id.rawValue; self.kind = kind; self.display = display ?? StageDisplay(order: 0)
        self.wip = wip; self.priority = priority; self.agent = agent; self.git = git; self.inputs = inputs; self.gates = gates
        self.onSuccess = onSuccess; self.returnsTo = returnsTo; self.onFail = onFail; self.onConflict = onConflict
        self.retry = retry; self.timeouts = timeouts; self.hooks = hooks; self.notify = notify
    }

    /// WIP the scheduler enforces; `nil` means unlimited (queue, terminal, human without `wip`).
    public var effectiveWIP: Int? {
        switch kind {
        case .agent, .gate: wip ?? 1
        case .merge: 1
        case .human: wip
        case .queue, .terminal: nil
        }
    }

    public var isReadOnly: Bool { agent?.permissions == .readOnly }

    /// Target and limit for merge conflicts (§8.5): explicit `on_conflict`, else first agent stage with limit 2.
    public func conflictReturn(in pipeline: PipelineConfig) -> StageReturn? {
        let target = onConflict?.stage ?? pipeline.firstAgentStage?.id
        return target.map { StageReturn(stage: $0, limit: onConflict?.limit ?? ConflictReturn.defaultLimit) }
    }

    public func returnLimit(to target: StageID) -> Int? { returnsTo.first { $0.stage == target }?.limit }
}

public struct ConflictReturn: Codable, Hashable, Sendable {
    public static let defaultLimit = 2
    public var stage: StageID?
    public var limit: Int
    public init(stage: StageID? = nil, limit: Int = defaultLimit) { self.stage = stage; self.limit = limit }
}

public enum AgentPermissions: String, Codable, Hashable, Sendable, CaseIterable {
    case write
    case readOnly = "read-only"
}

public enum AgentWorkspaceMode: String, Codable, Hashable, Sendable, CaseIterable {
    case task
    case freshReadonly = "fresh-readonly"
}

public struct AgentConfig: Codable, Hashable, Sendable {
    public static let supportedHarnesses: Set<String> = ["cursor-cli"]
    /// The built-in board MCP server; always present, never needs the allowlist (§9).
    public static let boardMcpServer = "kaban"

    public var harness: String
    /// Mandatory explicit model id; there is no default and `auto` is forbidden (decisions log, «Модели»).
    public var model: ModelID?
    public var skill: String?
    public var permissions: AgentPermissions
    public var mcp: [String]
    public var env: [String: String]
    public var workspace: AgentWorkspaceMode

    public init(harness: String = "cursor-cli", model: ModelID?, skill: String? = nil, permissions: AgentPermissions = .write,
                mcp: [String] = [AgentConfig.boardMcpServer], env: [String: String] = [:], workspace: AgentWorkspaceMode = .task) {
        self.harness = harness; self.model = model; self.skill = skill; self.permissions = permissions
        self.mcp = mcp; self.env = env; self.workspace = workspace
    }
}

/// Stage-level git overrides on top of the project policy (§8.4).
public struct StageGitOverride: Codable, Hashable, Sendable {
    public var extend: [String]
    public var deny: [String]
    public var when: GitOverrideCondition?
    public init(extend: [String] = [], deny: [String] = [], when: GitOverrideCondition? = nil) {
        self.extend = extend; self.deny = deny; self.when = when
    }
}

/// The only supported condition form: `return_reason == <reason>`.
public struct GitOverrideCondition: Codable, Hashable, Sendable {
    public var returnReason: ReturnReason
    public init(returnReason: ReturnReason) { self.returnReason = returnReason }

    public static func parse(_ text: String) -> GitOverrideCondition? {
        let parts = text.split(separator: "=", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard text.contains("=="), parts.count == 2, parts[0] == "return_reason", let r = ReturnReason(rawValue: parts[1]) else { return nil }
        return GitOverrideCondition(returnReason: r)
    }
    public var text: String { "return_reason == \(returnReason.rawValue)" }
}

/// Why the task entered its current stage from a later one. Used by `when:` and by prompts.
public enum ReturnReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// An agent called `return_to_stage` or a gate stage's `on_fail` fired.
    case returned
    case mergeConflict = "merge_conflict"
    /// `requestChanges` / `reject` to a stage / `moveTask`.
    case human
}

/// `retry: { max_attempts: 3, backoff: [30s, 2m] }` — approved 2026-10-04. Pauses are one fewer than attempts.
public struct RetryPolicy: Codable, Hashable, Sendable {
    public static let defaultMaxAttempts = 3
    public static let defaultBackoffSeconds = [30, 120]

    public var maxAttempts: Int
    /// Pauses in seconds between attempts.
    public var backoffSeconds: [Int]
    public init(maxAttempts: Int = defaultMaxAttempts, backoffSeconds: [Int] = defaultBackoffSeconds) {
        self.maxAttempts = maxAttempts; self.backoffSeconds = backoffSeconds
    }

    /// Pause before the next attempt after `failedAttempts` charged failures (1-based).
    /// Fewer pauses than needed (e.g. attempts granted by a human) repeat the last one; none means no pause.
    public func pause(afterFailedAttempts failedAttempts: Int) -> Int {
        guard !backoffSeconds.isEmpty, failedAttempts >= 1 else { return 0 }
        return backoffSeconds[min(failedAttempts - 1, backoffSeconds.count - 1)]
    }
}

public struct StageTimeouts: Codable, Hashable, Sendable {
    public var stallSeconds: Int
    public var wallSeconds: Int
    public init(stallSeconds: Int = 600, wallSeconds: Int = 3600) { self.stallSeconds = stallSeconds; self.wallSeconds = wallSeconds }
}

public struct StageHooks: Codable, Hashable, Sendable {
    public var onEnter: String?
    public var onExit: String?
    public init(onEnter: String? = nil, onExit: String? = nil) { self.onEnter = onEnter; self.onExit = onExit }
}

// MARK: - Projection to the protocol

public extension StageConfig {
    var summary: StageSummary {
        StageSummary(id: id, name: name, kind: kind, display: display, wip: effectiveWIP, model: agent?.model,
                     readOnly: isReadOnly, returnsTo: returnsTo, onSuccess: onSuccess,
                     maxAttempts: (kind == .agent || kind == .gate) ? retry.maxAttempts : nil)
    }
}

public extension PipelineConfig {
    func summary(projectId: ProjectID, versionHash: String?, issues: [ValidationIssue] = [], hasUncommittedEdits: Bool = false) -> PipelineSummary {
        PipelineSummary(projectId: projectId, versionHash: versionHash, gitPreset: git.preset, maxWaitingHuman: board.maxWaitingHuman,
                        maxRunsPerTask: board.maxRunsPerTask, stages: stages.map(\.summary), issues: issues,
                        hasUncommittedEdits: hasUncommittedEdits)
    }
}
