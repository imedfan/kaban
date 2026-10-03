import Foundation
import KabanProtocol

/// Inputs that are not in `pipeline.yaml` but affect validation.
public struct PipelineValidationContext: Sendable {
    /// Project MCP allowlist (`project_mcp_allow`, local DB, not in the repo). A stage server outside it is a warning.
    public var mcpAllowlist: Set<String>
    /// Stages that currently hold tasks in a non-terminal status (incl. `queued`): they cannot be removed.
    public var stagesWithActiveTasks: Set<StageID>
    public var supportedHarnesses: Set<String>

    public init(mcpAllowlist: Set<String> = [], stagesWithActiveTasks: Set<StageID> = [],
                supportedHarnesses: Set<String> = AgentConfig.supportedHarnesses) {
        self.mcpAllowlist = mcpAllowlist; self.stagesWithActiveTasks = stagesWithActiveTasks; self.supportedHarnesses = supportedHarnesses
    }
}

/// Result of validating a pipeline text. `config` is present whenever the YAML was structurally readable,
/// even if semantic errors exist (the editor still needs it); use `isValid` before applying.
public struct PipelineValidation: Hashable, Sendable {
    public var config: PipelineConfig?
    public var issues: [ValidationIssue]

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { config != nil && errors.isEmpty }

    /// Agent stages that need an explicit model (missing, placeholder or `auto`) — listed in the `pipeline_invalid` flag.
    public var stagesNeedingModel: [StageID] {
        guard let config else { return [] }
        return config.stages.filter { $0.kind == .agent && !PipelineValidator.hasExplicitModel($0.agent?.model) }.map(\.id)
    }

    /// Payload for the ephemeral `pipelineDraftValidated` event / `validatePipeline` reply.
    public func draftValidation(projectId: ProjectID, contentHash: String) -> PipelineDraftValidation {
        PipelineDraftValidation(projectId: projectId, contentHash: contentHash, issues: issues)
    }

    /// Reply of `updatePipeline` / `validatePipeline`.
    public func commandResult(contentHash: String) -> CommandResult {
        isValid ? .pipelineVersion(hash: contentHash) : .validationIssues(issues)
    }

    /// `unavailable: pipeline_invalid` for a version that reached `main` invalid; `nil` when valid.
    public func schedulerFlag(projectId: ProjectID) -> SchedulerFlag? {
        guard !isValid else { return nil }
        let models = stagesNeedingModel.map(\.rawValue)
        let detail = models.isEmpty ? errors.first.map { "\($0.path): \($0.message)" }
                                    : "stages without an explicit model: \(models.joined(separator: ", "))"
        return .projectUnavailable(projectId, .pipelineInvalid, detail: detail)
    }
}

/// Validator for `.kaban/pipeline.yaml` (architecture §3.1). Never throws for user errors:
/// syntax, type and semantic problems all come back as `ValidationIssue { path, code, message, severity }`.
public enum PipelineValidator {
    public static let maxWIP = 50
    public static let maxAttempts = 10
    public static let maxBackoffSeconds = 3600
    public static let stallRange = 60...7200
    public static let wallRange = 60...86400

    public static func validate(yaml text: String, context: PipelineValidationContext = .init()) -> PipelineValidation {
        let root: YAMLNode
        do {
            root = try MiniYAML.parse(text)
        } catch {
            return PipelineValidation(config: nil, issues: [ValidationIssue(path: "", code: KabanValidationCode.yamlSyntax,
                                                                             message: error.description, severity: .error)])
        }
        var parser = PipelineParser()
        guard let config = parser.parse(root) else { return PipelineValidation(config: nil, issues: parser.sink.issues) }
        var sink = parser.sink
        semantic(config, sourceIndex: parser.stageSourceIndex, context: context, sink: &sink)
        return PipelineValidation(config: config, issues: sink.issues)
    }

    /// Semantic validation of an already-typed config (e.g. built by the settings UI path in the daemon).
    public static func validate(config: PipelineConfig, context: PipelineValidationContext = .init()) -> PipelineValidation {
        var sink = IssueSink()
        semantic(config, sourceIndex: Array(config.stages.indices), context: context, sink: &sink)
        return PipelineValidation(config: config, issues: sink.issues)
    }

    static let idPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$")
    static let secretKeyWords = ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "PRIVATE_KEY", "CREDENTIAL", "ACCESS_KEY"]
    static let secretValuePrefixes = ["sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA", "-----BEGIN", "glpat-", "AIza"]

    static func semantic(_ c: PipelineConfig, sourceIndex: [Int], context: PipelineValidationContext, sink: inout IssueSink) {
        func sp(_ i: Int) -> String { "stages[\(sourceIndex[i])]" }

        // Board
        if !(1...100).contains(c.board.maxWaitingHuman) {
            sink.error("board.max_waiting_human", KabanValidationCode.limitOutOfRange, "max_waiting_human must be 1…100")
        }
        if !(0...100).contains(c.board.bounceLimitTotal) {
            sink.error("board.bounce_limit_total", KabanValidationCode.limitOutOfRange, "bounce_limit_total must be 0…100")
        }
        if !(1...1000).contains(c.board.maxRunsPerTask) {
            sink.error("board.max_runs_per_task", KabanValidationCode.limitOutOfRange, "max_runs_per_task must be 1…1000")
        }
        // Git (project)
        for (i, r) in c.git.allow.enumerated() { checkGitRule(r, path: "git.allow[\(i)]", granting: true, sink: &sink) }
        for (i, r) in c.git.deny.enumerated() { checkGitRule(r, path: "git.deny[\(i)]", granting: false, sink: &sink) }
        // Suspicious files
        if !(c.suspiciousFiles.maxFileMB > 0) {
            sink.error("suspicious_files.max_file_mb", KabanValidationCode.limitOutOfRange, "max_file_mb must be greater than 0")
        }

        guard !c.stages.isEmpty else {
            sink.error("stages", KabanValidationCode.noStages, "The pipeline has no stages")
            return
        }

        // Ids
        var firstIndex: [StageID: Int] = [:]
        for (i, s) in c.stages.enumerated() {
            let r = s.id.rawValue
            if idPattern.firstMatch(in: r, range: NSRange(r.startIndex..., in: r)) == nil {
                sink.error("\(sp(i)).id", KabanValidationCode.invalidId, "Stage id '\(r)' must be lowercase letters, digits, '-' or '_'")
            }
            if firstIndex[s.id] != nil {
                sink.error("\(sp(i)).id", KabanValidationCode.duplicateId, "Stage id '\(r)' is used more than once")
            } else {
                firstIndex[s.id] = i
            }
        }
        // Kinds count
        let queues = c.stages.indices.filter { c.stages[$0].kind == .queue }
        if queues.count != 1 {
            sink.error(queues.count > 1 ? "\(sp(queues[1])).kind" : "stages", KabanValidationCode.queueCount,
                       "Exactly one 'queue' stage (Backlog) is required, found \(queues.count)")
        }
        let merges = c.stages.indices.filter { c.stages[$0].kind == .merge }
        if merges.count != 1 {
            sink.error(merges.count > 1 ? "\(sp(merges[1])).kind" : "stages", KabanValidationCode.mergeCount,
                       "Exactly one 'merge' stage is required, found \(merges.count)")
        }
        if !c.stages.contains(where: { $0.kind == .terminal }) {
            sink.error("stages", KabanValidationCode.terminalMissing, "A 'terminal' stage (Done) is required")
        }

        // Per-stage checks
        for (i, s) in c.stages.enumerated() {
            let p = sp(i)
            func ref(_ id: StageID, _ path: String) -> Bool {
                if firstIndex[id] == nil {
                    sink.error(path, KabanValidationCode.unknownStage, "Stage '\(s.id)' refers to unknown stage '\(id)'")
                    return false
                }
                return true
            }
            // on_success
            if s.kind == .terminal {
                if s.onSuccess != nil {
                    sink.error("\(p).on_success", KabanValidationCode.terminalHasOnSuccess, "Terminal stage '\(s.id)' cannot have on_success")
                }
            } else if let next = s.onSuccess {
                _ = ref(next, "\(p).on_success")
            } else {
                sink.error("\(p).on_success", KabanValidationCode.onSuccessMissing, "Stage '\(s.id)' needs on_success")
            }

            // WIP
            if let w = s.wip {
                switch s.kind {
                case .queue, .terminal:
                    sink.warning("\(p).wip", KabanValidationCode.fieldNotAllowedForKind, "wip is ignored for \(s.kind.rawValue) stages")
                case .merge where w != 1:
                    sink.error("\(p).wip", ValidationCode.wipOutOfRange, "The merge stage always has wip 1")
                default:
                    if !(1...maxWIP).contains(w) {
                        sink.error("\(p).wip", ValidationCode.wipOutOfRange, "wip must be 1…\(maxWIP)")
                    }
                }
            }

            // Agent
            if s.kind == .agent {
                if let a = s.agent {
                    validateAgent(a, stage: s, path: "\(p).agent", context: context, sink: &sink)
                } else {
                    sink.error("\(p).agent", KabanValidationCode.agentMissing, "Agent stage '\(s.id)' needs an 'agent' block with an explicit model")
                    sink.error("\(p).agent.model", ValidationCode.modelMissing, "Stage '\(s.id)' has no model; choose an explicit model (auto is not allowed)")
                }
            } else if s.agent != nil {
                sink.error("\(p).agent", KabanValidationCode.fieldNotAllowedForKind, "Only agent stages can have 'agent'")
            }

            // Gates
            if s.kind == .queue || s.kind == .terminal || s.kind == .human, !s.gates.isEmpty {
                sink.error("\(p).gates", KabanValidationCode.fieldNotAllowedForKind, "\(s.kind.rawValue) stages cannot have gates")
            }
            if s.kind == .gate && s.gates.isEmpty {
                sink.error("\(p).gates", KabanValidationCode.missingField, "Gate stage '\(s.id)' needs at least one gate command")
            }

            // Returns
            if !s.returnsTo.isEmpty && s.kind != .agent {
                sink.error("\(p).returns_to", KabanValidationCode.returnsNotAllowed,
                           "Only agent stages return by returns_to; \(s.kind.rawValue) stages use \(s.kind == .gate ? "on_fail" : s.kind == .merge ? "on_conflict" : "human commands")")
            }
            var seenTargets = Set<StageID>()
            for (j, r) in s.returnsTo.enumerated() {
                let rp = "\(p).returns_to[\(j)]"
                guard ref(r.stage, "\(rp).stage") else { continue }
                if !seenTargets.insert(r.stage).inserted {
                    sink.error("\(rp).stage", KabanValidationCode.duplicateId, "Return target '\(r.stage)' is listed twice")
                }
                if !c.isUpstream(r.stage, of: s.id) {
                    sink.error("\(rp).stage", ValidationCode.returnsForward, "Stage '\(s.id)' can only return backwards along on_success, not to '\(r.stage)'")
                }
                if !(1...100).contains(r.limit) {
                    sink.error("\(rp).limit", KabanValidationCode.limitOutOfRange, "Return limit must be 1…100")
                }
            }
            if let f = s.onFail {
                if s.kind != .gate {
                    sink.error("\(p).on_fail", KabanValidationCode.fieldNotAllowedForKind, "on_fail is only for gate stages")
                } else if ref(f.stage, "\(p).on_fail.stage") {
                    if !c.isUpstream(f.stage, of: s.id) {
                        sink.error("\(p).on_fail.stage", ValidationCode.returnsForward, "on_fail of '\(s.id)' must point backwards, not to '\(f.stage)'")
                    }
                    if c.stage(f.stage)?.kind != .agent {
                        sink.error("\(p).on_fail.stage", KabanValidationCode.invalidValue, "on_fail must target an agent stage")
                    }
                    if !(1...100).contains(f.limit) {
                        sink.error("\(p).on_fail.limit", KabanValidationCode.limitOutOfRange, "on_fail limit must be 1…100")
                    }
                }
            }
            if let oc = s.onConflict {
                if s.kind != .merge {
                    sink.error("\(p).on_conflict", KabanValidationCode.fieldNotAllowedForKind, "on_conflict is only for the merge stage")
                } else {
                    if let t = oc.stage, ref(t, "\(p).on_conflict.stage") {
                        if c.stage(t)?.kind != .agent {
                            sink.error("\(p).on_conflict.stage", KabanValidationCode.invalidValue, "on_conflict must target an agent stage")
                        } else if !c.isUpstream(t, of: s.id) {
                            sink.error("\(p).on_conflict.stage", ValidationCode.returnsForward, "on_conflict must point backwards")
                        }
                    }
                    if !(1...100).contains(oc.limit) {
                        sink.error("\(p).on_conflict.limit", KabanValidationCode.limitOutOfRange, "on_conflict limit must be 1…100")
                    }
                }
            }
            if s.kind == .merge && s.onConflict?.stage == nil && c.firstAgentStage == nil {
                sink.error("\(p).on_conflict", KabanValidationCode.missingField, "No agent stage to send merge conflicts to")
            }

            // Retry & timeouts (meaningful for agent and gate stages)
            if s.kind == .agent || s.kind == .gate || s.kind == .merge {
                if !(1...maxAttempts).contains(s.retry.maxAttempts) {
                    sink.error("\(p).retry.max_attempts", KabanValidationCode.attemptsOutOfRange, "max_attempts must be 1…\(maxAttempts)")
                } else if s.retry.backoffSeconds.count > s.retry.maxAttempts - 1 {
                    sink.error("\(p).retry.backoff", ValidationCode.backoffTooLong,
                               "backoff has \(s.retry.backoffSeconds.count) pauses; at most max_attempts − 1 = \(s.retry.maxAttempts - 1)")
                }
                for (j, b) in s.retry.backoffSeconds.enumerated() where !(1...maxBackoffSeconds).contains(b) {
                    sink.error("\(p).retry.backoff[\(j)]", KabanValidationCode.durationOutOfRange, "Each pause must be 1s…1h")
                }
                if !stallRange.contains(s.timeouts.stallSeconds) {
                    sink.error("\(p).timeouts.stall", KabanValidationCode.durationOutOfRange, "stall timeout must be 1m…2h")
                }
                if !wallRange.contains(s.timeouts.wallSeconds) {
                    sink.error("\(p).timeouts.wall", KabanValidationCode.durationOutOfRange, "wall timeout must be 1m…24h")
                } else if s.timeouts.stallSeconds > s.timeouts.wallSeconds {
                    sink.error("\(p).timeouts.stall", KabanValidationCode.durationOutOfRange, "stall timeout cannot exceed the wall timeout")
                }
            }

            // Stage git overrides
            if let g = s.git {
                if s.kind != .agent {
                    sink.error("\(p).git", KabanValidationCode.fieldNotAllowedForKind, "git overrides are only for agent stages")
                }
                for (j, r) in g.extend.enumerated() { checkGitRule(r, path: "\(p).git.extend[\(j)]", granting: true, sink: &sink) }
                for (j, r) in g.deny.enumerated() { checkGitRule(r, path: "\(p).git.deny[\(j)]", granting: false, sink: &sink) }
            }
        }

        // Graph: terminal reachable from every stage, no on_success cycles.
        for (i, s) in c.stages.enumerated() where s.kind != .terminal {
            var seen = Set<StageID>()
            var cursor: StageID? = s.id
            var outcome: String?
            while let id = cursor {
                if !seen.insert(id).inserted { outcome = KabanValidationCode.onSuccessCycle; break }
                guard let st = c.stage(id) else { outcome = KabanValidationCode.unknownStage; break }
                if st.kind == .terminal { break }
                cursor = st.onSuccess
                if cursor == nil { outcome = ValidationCode.terminalUnreachable }
            }
            switch outcome {
            case KabanValidationCode.onSuccessCycle?:
                sink.error("\(sp(i)).on_success", KabanValidationCode.onSuccessCycle, "on_success from '\(s.id)' loops without reaching a terminal stage")
            case .some:
                sink.error("\(sp(i)).on_success", ValidationCode.terminalUnreachable, "No on_success path from '\(s.id)' to a terminal stage")
            case nil: break
            }
        }

        // Stages that still hold tasks cannot disappear.
        let ids = Set(c.stages.map(\.id))
        for removed in context.stagesWithActiveTasks.subtracting(ids).sorted(by: { $0.rawValue < $1.rawValue }) {
            sink.error("stages", ValidationCode.stageHasActiveTasks, "Stage '\(removed)' still has active tasks and cannot be removed")
        }
    }

    static func validateAgent(_ a: AgentConfig, stage s: StageConfig, path p: String, context: PipelineValidationContext, sink: inout IssueSink) {
        if let m = a.model?.rawValue, isAuto(m) {
            sink.error("\(p).model", ValidationCode.modelAutoForbidden, "Stage '\(s.id)' uses 'auto'; Kaban needs an explicit model")
        } else if !hasExplicitModel(a.model) {
            sink.error("\(p).model", ValidationCode.modelMissing, "Stage '\(s.id)' has no model; choose an explicit model (auto is not allowed)")
        }
        if !context.supportedHarnesses.contains(a.harness) {
            sink.error("\(p).harness", KabanValidationCode.harnessUnsupported,
                       "Harness '\(a.harness)' is not supported; available: \(context.supportedHarnesses.sorted().joined(separator: ", "))")
        }
        for (j, server) in a.mcp.enumerated() where server != AgentConfig.boardMcpServer && !context.mcpAllowlist.contains(server) {
            sink.warning("\(p).mcp[\(j)]", ValidationCode.mcpNotAllowlisted,
                         "MCP server '\(server)' is not enabled in the project allowlist; it will not be connected")
        }
        for key in a.env.keys.sorted() {
            let value = a.env[key] ?? ""
            let upper = key.uppercased()
            if secretKeyWords.contains(where: { upper.contains($0) }) || secretValuePrefixes.contains(where: { value.hasPrefix($0) }) {
                sink.error("\(p).env.\(key)", ValidationCode.secretInEnv,
                           "env '\(key)' looks like a secret; secrets are referenced by Keychain key name, never stored in pipeline.yaml")
            }
        }
    }

    static func isAuto(_ model: String) -> Bool { model.trimmingCharacters(in: .whitespaces).lowercased() == "auto" }

    /// An explicit model id: non-empty, not a template placeholder like `<model-id>`, not `auto`.
    public static func hasExplicitModel(_ model: ModelID?) -> Bool {
        guard let m = model?.rawValue.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return false }
        if m.hasPrefix("<") && m.hasSuffix(">") { return false }
        return !isAuto(m)
    }

    static func checkGitRule(_ rule: String, path: String, granting: Bool, sink: inout IssueSink) {
        let r = GitPolicyResolver.normalize(rule)
        if r.isEmpty {
            sink.error(path, KabanValidationCode.invalidValue, "Empty git rule")
            return
        }
        if granting && GitPolicyResolver.violatesHardInvariant(r) {
            sink.error(path, KabanValidationCode.gitHardInvariant, "'\(r)' is a hard invariant and cannot be allowed by any policy")
        } else if !GitPolicyResolver.isKnown(r) {
            sink.warning(path, KabanValidationCode.gitUnknownCommand, "Unknown git command '\(r)'")
        }
    }
}
