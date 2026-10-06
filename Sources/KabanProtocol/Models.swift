import Foundation

/// Запись `model_catalog` (§4). `auto` хранится с `forbidden = true` и в `listModels()` не отдаётся.
public struct ModelInfo: Codable, Hashable, Sendable {
    public var id: ModelID
    public var name: String
    public var pool: ModelPool
    public var needsReview: Bool
    public var forbidden: Bool
    public var missingSince: Date?

    public init(id: ModelID, name: String, pool: ModelPool, needsReview: Bool = false, forbidden: Bool = false, missingSince: Date? = nil) {
        self.id = id; self.name = name; self.pool = pool; self.needsReview = needsReview; self.forbidden = forbidden; self.missingSince = missingSince
    }
}

public struct ModelPoolRule: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case builtin, user }
    public var pattern: String
    public var pool: ModelPool
    public var source: Source
    public init(pattern: String, pool: ModelPool, source: Source) { self.pattern = pattern; self.pool = pool; self.source = source }

    /// Встроенное правило одно: `composer-*` → Cm, всё остальное → Om.
    public static let builtin = [ModelPoolRule(pattern: "composer-*", pool: .cm, source: .builtin)]
}

public enum ModelPoolResolver {
    /// Пользовательские правила важнее встроенных; без совпадений — Om.
    public static func pool(for model: ModelID, rules: [ModelPoolRule]) -> ModelPool {
        let ordered = rules.filter { $0.source == .user } + rules.filter { $0.source == .builtin }
        for rule in ordered where glob(rule.pattern, matches: model.rawValue) { return rule.pool }
        return .om
    }

    public static func matches(_ pattern: String, _ value: String) -> Bool { glob(pattern, matches: value) }

    static func glob(_ pattern: String, matches s: String) -> Bool {
        if pattern.hasSuffix("*") { return s.hasPrefix(String(pattern.dropLast())) }
        return pattern == s
    }
}

/// Флаг модели (§3.2, §4 `model_flag`). `actual` есть только при `substituted`.
public struct ModelFlag: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable { case unavailable, substituted }
    public var modelId: ModelID
    public var reason: Reason
    public var requested: String
    public var actual: String?
    public var fallbackModel: String?
    public var since: Date
    public var lastProbeAt: Date?

    public init(modelId: ModelID, reason: Reason, requested: String, actual: String? = nil, fallbackModel: String? = nil, since: Date, lastProbeAt: Date? = nil) {
        self.modelId = modelId; self.reason = reason; self.requested = requested; self.actual = actual
        self.fallbackModel = fallbackModel; self.since = since; self.lastProbeAt = lastProbeAt
    }
}
