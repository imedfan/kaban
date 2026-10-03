import KabanProtocol

/// Validation codes used by KabanKit in addition to `KabanProtocol.ValidationCode`.
/// Proposed for promotion into `KabanProtocol.ValidationCode` so the editor can localize them.
public enum KabanValidationCode {
    // Syntax / structure
    public static let yamlSyntax = "yaml_syntax"
    public static let typeMismatch = "type_mismatch"
    public static let missingField = "missing_field"
    public static let unknownKey = "unknown_key"                      // warning
    public static let invalidValue = "invalid_value"
    public static let versionUnsupported = "version_unsupported"
    // Stages graph
    public static let noStages = "no_stages"
    public static let duplicateId = "duplicate_id"
    public static let invalidId = "invalid_id"
    public static let unknownStage = "unknown_stage"
    public static let queueCount = "queue_count"
    public static let mergeCount = "merge_count"
    public static let terminalMissing = "terminal_missing"
    public static let onSuccessMissing = "on_success_missing"
    public static let onSuccessCycle = "on_success_cycle"
    public static let terminalHasOnSuccess = "terminal_has_on_success"
    public static let fieldNotAllowedForKind = "field_not_allowed_for_kind"
    public static let returnsNotAllowed = "returns_not_allowed"
    // Agent
    public static let agentMissing = "agent_missing"
    public static let harnessUnsupported = "harness_unsupported"
    // Limits
    public static let limitOutOfRange = "limit_out_of_range"
    public static let durationOutOfRange = "duration_out_of_range"
    public static let attemptsOutOfRange = "attempts_out_of_range"
    // Git
    public static let gitHardInvariant = "git_hard_invariant"
    public static let gitConditionInvalid = "git_condition_invalid"
    public static let gitUnknownCommand = "git_unknown_command"       // warning
}
