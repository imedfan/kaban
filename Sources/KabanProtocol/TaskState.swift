import Foundation

/// Статус задачи (§3.2). Отдельного `failed` нет.
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case queued, running, gating
    case retryWait = "retry_wait"
    case waitingHuman = "waiting_human"
    case paused, blocked, done, cancelled

    /// Занимает ли задача WIP-слот стадии.
    public var occupiesWIP: Bool { self == .running || self == .gating || self == .retryWait }

    /// Занимает ли задача WIP-слот стадии данного вида (§3.2, v0.11.2): в `human`-стадии — все, кроме `queued`
    /// и терминальных; в остальных — как `occupiesWIP`.
    public func occupiesWIP(in kind: StageKind) -> Bool {
        switch kind {
        case .human: self != .queued && self != .done && self != .cancelled
        case .queue, .terminal: false
        case .agent, .gate, .merge: occupiesWIP
        }
    }
}

public enum WaitingHumanReason: String, Codable, Sendable, CaseIterable {
    case question, review
    case retriesExhausted = "retries_exhausted"
    case bounceLimit = "bounce_limit"
    case conflictLimit = "conflict_limit"
    case runLimit = "run_limit"
    case modelSubstituted = "model_substituted"
    case gitDenials = "git_denials"
    case incident
    case suspiciousFiles = "suspicious_files"
    case invalidResult = "invalid_result"

    /// `review` не считается в `max_waiting_human`.
    public var countsTowardMaxWaitingHuman: Bool { self != .review }
}

/// Подпись на карточке в очереди. `nil` — обычная очередь.
public enum QueuedReason: String, Codable, Sendable, CaseIterable {
    case wipFull = "wip_full"
    case quotaCm = "quota_cm"
    case quotaOm = "quota_om"
    case modelFlag = "model_flag"
}

public enum RetryWaitReason: String, Codable, Sendable, CaseIterable {
    case crash
    case stallTimeout = "stall_timeout"
    case wallTimeout = "wall_timeout"
    case noFinalCall = "no_final_call"
    case gateFailed = "gate_failed"
    case rateLimit = "rate_limit"
    case runnerAuth = "runner_auth"
    case daemonRestart = "daemon_restart"
    case silentExit = "silent_exit"
    /// Read-only стадия оставила изменения: откат и один повтор с замечанием; попытка списывается (§6.3).
    case readonlyViolation = "readonly_violation"

    /// Причины, при которых попытка и `max_runs_per_task` не списываются (§3.2).
    public var chargesAttempt: Bool {
        switch self {
        case .rateLimit, .runnerAuth, .daemonRestart, .silentExit: false
        default: true
        }
    }
}

public enum BlockedReason: String, Codable, Sendable, CaseIterable {
    case mainDirty = "main_dirty"
}

/// Статус вместе с причиной. На проводе — плоско: `{"status": "waiting_human", "reason": "question"}`.
public enum TaskState: Hashable, Sendable {
    case queued(QueuedReason?)
    case running
    case gating
    case retryWait(RetryWaitReason)
    case waitingHuman(WaitingHumanReason)
    case paused
    case blocked(BlockedReason)
    case done
    case cancelled

    public var status: TaskStatus {
        switch self {
        case .queued: .queued
        case .running: .running
        case .gating: .gating
        case .retryWait: .retryWait
        case .waitingHuman: .waitingHuman
        case .paused: .paused
        case .blocked: .blocked
        case .done: .done
        case .cancelled: .cancelled
        }
    }

    public var reasonRawValue: String? {
        switch self {
        case .queued(let r): r?.rawValue
        case .retryWait(let r): r.rawValue
        case .waitingHuman(let r): r.rawValue
        case .blocked(let r): r.rawValue
        default: nil
        }
    }

    public var countsTowardMaxWaitingHuman: Bool {
        if case .waitingHuman(let r) = self { return r.countsTowardMaxWaitingHuman }
        return false
    }
}

extension TaskState: Codable {
    enum CodingKeys: String, CodingKey { case status, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(TaskStatus.self, forKey: .status)
        func reason<R: Decodable>(_: R.Type) throws -> R { try c.decode(R.self, forKey: .reason) }
        switch status {
        case .queued: self = .queued(try c.decodeIfPresent(QueuedReason.self, forKey: .reason))
        case .running: self = .running
        case .gating: self = .gating
        case .retryWait: self = .retryWait(try reason(RetryWaitReason.self))
        case .waitingHuman: self = .waitingHuman(try reason(WaitingHumanReason.self))
        case .paused: self = .paused
        case .blocked: self = .blocked(try reason(BlockedReason.self))
        case .done: self = .done
        case .cancelled: self = .cancelled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(reasonRawValue, forKey: .reason)
    }
}

/// Статус run (§3.2) и причина завершения.
public enum RunStatus: String, Codable, Sendable { case starting, running, succeeded, failed, killed }

public enum RunEndReason: String, Codable, Sendable {
    case crash
    case stallTimeout = "stall_timeout"
    case wallTimeout = "wall_timeout"
    case noFinalCall = "no_final_call"
    case gateFailed = "gate_failed"
    case rateLimit = "rate_limit"
    case runnerAuth = "runner_auth"
    case daemonRestart = "daemon_restart"
    case silentExit = "silent_exit"
    case modelSubstituted = "model_substituted"
    case readonlyViolation = "readonly_violation"
    case completed, returned
    case askedHuman = "asked_human"
    case pausedByHuman = "paused_by_human"
    case movedByHuman = "moved_by_human"
}
