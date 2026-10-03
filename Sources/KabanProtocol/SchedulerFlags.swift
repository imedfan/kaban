import Foundation

/// Пул квоты Cursor: Cm — модели `composer-*`, Om — все остальные (§4 `model_pool_rule`).
public enum ModelPool: String, Codable, Sendable, CaseIterable { case cm, om }

/// Флаги планировщика из таблицы §3.2. Флаг — не статус задачи: задачи остаются `queued`, текущие runs доигрывают.
public enum SchedulerFlag: Hashable, Sendable {
    // Мак
    case macPaused
    case rateLimited(cooldownUntil: Date, step: Int)
    /// Кончилась месячная квота, пул неизвестен — встаёт весь Мак.
    case usageExhaustedUnknown(resetsAt: Date?)
    case runnerUnavailable(RunnerUnavailableReason)
    // Пул
    /// Известно, какой пул кончился: встают только стадии на моделях этого пула.
    case poolUsageExhausted(ModelPool, resetsAt: Date?)
    // Проект
    case projectPaused(ProjectID)
    case intakePaused(ProjectID)
    case projectUnavailable(ProjectID, ProjectUnavailableReason, detail: String?)
    case mergeBlocked(ProjectID)

    public enum Level: String, Codable, Sendable { case mac, pool, project }

    public var level: Level {
        switch self {
        case .macPaused, .rateLimited, .usageExhaustedUnknown, .runnerUnavailable: .mac
        case .poolUsageExhausted: .pool
        case .projectPaused, .intakePaused, .projectUnavailable, .mergeBlocked: .project
        }
    }
}

public enum RunnerUnavailableReason: String, Codable, Sendable, CaseIterable {
    case agentMissing = "agent_missing"
    case agentNotRunnable = "agent_not_runnable"
    case agentNotLoggedIn = "agent_not_logged_in"
    case runnerAuth = "runner_auth"
}

public enum ProjectUnavailableReason: String, Codable, Sendable, CaseIterable {
    case projectMissing = "project_missing"
    case noPipeline = "no_pipeline"
    case pipelineInvalid = "pipeline_invalid"
    case mcpUnexpected = "mcp_unexpected"
}

/// Плоская форма на проводе: `{"level","flag","reason","projectId","pool",...}` — удобно и для фронта, и для логов.
extension SchedulerFlag: Codable {
    enum CodingKeys: String, CodingKey { case level, flag, reason, projectId, pool, until, step, resetsAt, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let flag = try c.decode(String.self, forKey: .flag)
        let level = try c.decode(Level.self, forKey: .level)
        switch (level, flag) {
        case (.mac, "paused"): self = .macPaused
        case (.mac, "rate_limited"):
            self = .rateLimited(cooldownUntil: try c.decode(Date.self, forKey: .until), step: try c.decode(Int.self, forKey: .step))
        case (.mac, "usage_exhausted"): self = .usageExhaustedUnknown(resetsAt: try c.decodeIfPresent(Date.self, forKey: .resetsAt))
        case (.mac, "runner_unavailable"): self = .runnerUnavailable(try c.decode(RunnerUnavailableReason.self, forKey: .reason))
        case (.pool, "usage_exhausted"):
            self = .poolUsageExhausted(try c.decode(ModelPool.self, forKey: .pool), resetsAt: try c.decodeIfPresent(Date.self, forKey: .resetsAt))
        case (.project, "paused"): self = .projectPaused(try c.decode(ProjectID.self, forKey: .projectId))
        case (.project, "intake_paused"): self = .intakePaused(try c.decode(ProjectID.self, forKey: .projectId))
        case (.project, "unavailable"):
            self = .projectUnavailable(try c.decode(ProjectID.self, forKey: .projectId),
                                       try c.decode(ProjectUnavailableReason.self, forKey: .reason),
                                       detail: try c.decodeIfPresent(String.self, forKey: .detail))
        case (.project, "merge_blocked"): self = .mergeBlocked(try c.decode(ProjectID.self, forKey: .projectId))
        default:
            throw DecodingError.dataCorruptedError(forKey: .flag, in: c, debugDescription: "Неизвестный флаг \(level.rawValue)/\(flag)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(level, forKey: .level)
        switch self {
        case .macPaused:
            try c.encode("paused", forKey: .flag); try c.encode("manual", forKey: .reason)
        case .rateLimited(let until, let step):
            try c.encode("rate_limited", forKey: .flag); try c.encode(until, forKey: .until); try c.encode(step, forKey: .step)
        case .usageExhaustedUnknown(let resetsAt):
            try c.encode("usage_exhausted", forKey: .flag); try c.encode("unknown", forKey: .reason)
            try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        case .runnerUnavailable(let r):
            try c.encode("runner_unavailable", forKey: .flag); try c.encode(r, forKey: .reason)
        case .poolUsageExhausted(let pool, let resetsAt):
            try c.encode("usage_exhausted", forKey: .flag); try c.encode(pool, forKey: .pool)
            try c.encode(pool.rawValue, forKey: .reason); try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        case .projectPaused(let p):
            try c.encode("paused", forKey: .flag); try c.encode(p, forKey: .projectId); try c.encode("manual", forKey: .reason)
        case .intakePaused(let p):
            try c.encode("intake_paused", forKey: .flag); try c.encode(p, forKey: .projectId); try c.encode("max_waiting_human", forKey: .reason)
        case .projectUnavailable(let p, let r, let detail):
            try c.encode("unavailable", forKey: .flag); try c.encode(p, forKey: .projectId); try c.encode(r, forKey: .reason)
            try c.encodeIfPresent(detail, forKey: .detail)
        case .mergeBlocked(let p):
            try c.encode("merge_blocked", forKey: .flag); try c.encode(p, forKey: .projectId); try c.encode("main_dirty", forKey: .reason)
        }
    }
}
