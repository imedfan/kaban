import KabanKit

/// Explicit scenario for an agent invocation; callers supply it rather than
/// deriving a human question or completion from task text.
public enum FakeAgentScenario: Sendable {
    case question(String)
    case completed(summary: String)
}

public enum FakeDriver {
    /// A pure mapping. Acknowledgement of lifecycle work means simulated only.
    public static func result(for effect: PendingEffect, agent: FakeAgentScenario) throws -> FakeEffectResult {
        guard effect.version == 1 else { throw StoreError.unsupportedEffect }
        switch effect.effect {
        case .startAgentRun:
            switch agent { case .question(let text): return .question(text); case .completed(let summary): return .completed(summary: summary) }
        case .runResultCheck: return .clean
        case .runGates: return .gatesPassed
        case .killRun, .saveWipAndRollback, .commitStage, .scheduleRetry, .expireGitGrants, .cleanupClone, .notifyHuman:
            return .acknowledged
        default: throw StoreError.unsupportedEffect
        }
    }
}
