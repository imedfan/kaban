import Foundation
import KabanProtocol

/// Inputs that are not in `pipeline.yaml` but affect validation.
public struct PipelineValidationContext: Sendable {
    /// Project MCP allowlist (`project_mcp_allow`, local DB, not in the repo). A stage server outside it is a warning.
    public var mcpAllowlist: Set<String>
    /// Stages that currently hold tasks in a non-terminal status (incl. `queued`): they cannot be removed.
    public var stagesWithActiveTasks: Set<StageID>
    public var activeStageKinds: [StageID: StageKind]
    public var supportedHarnesses: Set<String>

    public init(mcpAllowlist: Set<String> = [], stagesWithActiveTasks: Set<StageID> = [],
                supportedHarnesses: Set<String> = AgentConfig.supportedHarnesses, activeStageKinds: [StageID: StageKind] = [:]) {
        self.mcpAllowlist = mcpAllowlist; self.stagesWithActiveTasks = stagesWithActiveTasks; self.supportedHarnesses = supportedHarnesses
        self.activeStageKinds = activeStageKinds
    }
}

/// Result of validating a pipeline text. `config` is present whenever the YAML was structurally readable,
/// even if semantic errors exist (the editor still needs it); use `isValid` before applying.
public struct PipelineValidation: Hashable, Sendable {
    public var config: PipelineConfig?
    public var issues: [ValidationIssue]
    public init(config: PipelineConfig?, issues: [ValidationIssue]) { self.config = config; self.issues = issues }

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { config != nil && errors.isEmpty }

    /// Agent stages that need an explicit model (missing, placeholder or `auto`) — listed in the `pipeline_invalid` flag.
    public var stagesNeedingModel: [StageID] {
        guard let config else { return [] }
        return config.stages.filter { $0.kind == .agent && !PipelineValidator.hasExplicitModel($0.agent?.model) }.map(\.id)
    }

    /// Payload for the ephemeral `pipelineDraftValidated` event / `validatePipeline` reply. `resolved` is the draft run through
    /// the same resolver as `main` (returns, `gitPolicy`, `defaultReturnStage`) whenever it parsed, even with errors;
    /// `nil` only when it did not parse (arch. v0.11.6 §2). A draft has no `versionHash`.
    public func draftValidation(projectId: ProjectID, contentHash: String) -> PipelineDraftValidation {
        PipelineDraftValidation(projectId: projectId, contentHash: contentHash, issues: issues,
                                resolved: config?.summary(projectId: projectId, versionHash: nil, issues: issues))
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
            return PipelineValidation(config: nil, issues: [ValidationIssue(path: "", code: ValidationCode.yamlSyntax,
                                                                             message: error.description, severity: .error,
                                                                             params: ["line": String(error.line)])])
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

    /// Duration in YAML notation for `params` (`90` → `90s`, `600` → `10m`, `7200` → `2h`).
    static func durationText(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    /// `params` for `*_out_of_range`: `{label}` is the YAML field name (the editor maps it to its caption), `{min}`/`{max}`.
    static func range(_ label: String?, _ r: ClosedRange<Int>, duration: Bool = false) -> [String: String] {
        func f(_ n: Int) -> String { duration ? durationText(n) : "\(n)" }
        var p: [String: String] = ["min": f(r.lowerBound), "max": f(r.upperBound)]
        if let label { p["label"] = label }
        return p
    }

    static func semantic(_ c: PipelineConfig, sourceIndex: [Int], context: PipelineValidationContext, sink: inout IssueSink) {
        func sp(_ i: Int) -> String { "stages[\(sourceIndex[i])]" }

        // Board
        if !(1...100).contains(c.board.maxWaitingHuman) {
            sink.error("board.max_waiting_human", ValidationCode.limitOutOfRange, "max_waiting_human must be 1…100",
                       params: range("max_waiting_human", 1...100))
        }
        if !(0...100).contains(c.board.bounceLimitTotal) {
            sink.error("board.bounce_limit_total", ValidationCode.limitOutOfRange, "bounce_limit_total must be 0…100",
                       params: range("bounce_limit_total", 0...100))
        }
        if !(1...1000).contains(c.board.maxRunsPerTask) {
            sink.error("board.max_runs_per_task", ValidationCode.limitOutOfRange, "max_runs_per_task must be 1…1000",
                       params: range("max_runs_per_task", 1...1000))
        }
        // Git (project)
        for (i, r) in c.git.allow.enumerated() { checkGitRule(r, path: "git.allow[\(i)]", granting: true, sink: &sink) }
        for (i, r) in c.git.deny.enumerated() { checkGitRule(r, path: "git.deny[\(i)]", granting: false, sink: &sink) }
        // Suspicious files
        if !c.suspiciousFiles.maxFileMB.isFinite || !(c.suspiciousFiles.maxFileMB > 0) {
            sink.error("suspicious_files.max_file_mb", ValidationCode.limitOutOfRange, "max_file_mb must be finite and greater than 0",
                       params: ["label": "max_file_mb"])   // no upper bound: the §4.1 text needs {max}, UI falls back to `message`
        }

        guard !c.stages.isEmpty else {
            sink.error("stages", ValidationCode.noStages, "The pipeline has no stages")
            return
        }

        // Ids
        var firstIndex: [StageID: Int] = [:]
        for (i, s) in c.stages.enumerated() {
            sink.stage = s.id
            defer { sink.stage = nil }
            let r = s.id.rawValue
            if idPattern.firstMatch(in: r, range: NSRange(r.startIndex..., in: r)) == nil {
                sink.error("\(sp(i)).id", ValidationCode.invalidId, "Stage id '\(r)' must be lowercase letters, digits, '-' or '_'")
            }
            if firstIndex[s.id] != nil {
                sink.error("\(sp(i)).id", ValidationCode.duplicateId, "Stage id '\(r)' is used more than once", params: ["id": r])
            } else {
                firstIndex[s.id] = i
            }
        }
        // Kinds count
        let queues = c.stages.indices.filter { c.stages[$0].kind == .queue }
        if queues.count != 1 {
            sink.error(queues.count > 1 ? "\(sp(queues[1])).kind" : "stages", ValidationCode.queueCount,
                       "Exactly one 'queue' stage (Backlog) is required, found \(queues.count)",
                       stageId: queues.count > 1 ? c.stages[queues[1]].id : nil, params: ["n": "\(queues.count)"])
        }
        let merges = c.stages.indices.filter { c.stages[$0].kind == .merge }
        if merges.count != 1 {
            sink.error(merges.count > 1 ? "\(sp(merges[1])).kind" : "stages", ValidationCode.mergeCount,
                       "Exactly one 'merge' stage is required, found \(merges.count)",
                       stageId: merges.count > 1 ? c.stages[merges[1]].id : nil, params: ["n": "\(merges.count)"])
        }
        if !c.stages.contains(where: { $0.kind == .terminal }) {
            sink.error("stages", ValidationCode.terminalMissing, "A 'terminal' stage (Done) is required")
        }

        // Per-stage checks (every issue carries `stageId = s.id` through `sink.stage`)
        for (i, s) in c.stages.enumerated() {
            sink.stage = s.id
            defer { sink.stage = nil }
            let p = sp(i)
            func ref(_ id: StageID, _ path: String) -> Bool {
                if firstIndex[id] == nil {
                    sink.error(path, ValidationCode.unknownStage, "Stage '\(s.id)' refers to unknown stage '\(id)'", params: ["id": id.rawValue])
                    return false
                }
                return true
            }
            // on_success
            if s.kind == .terminal {
                if s.onSuccess != nil {
                    sink.error("\(p).on_success", ValidationCode.terminalHasOnSuccess, "Terminal stage '\(s.id)' cannot have on_success")
                }
            } else if let next = s.onSuccess {
                _ = ref(next, "\(p).on_success")
            } else {
                sink.error("\(p).on_success", ValidationCode.onSuccessMissing, "Stage '\(s.id)' needs on_success")
            }

            // WIP
            if let w = s.wip {
                switch s.kind {
                case .queue, .terminal:
                    sink.warning("\(p).wip", ValidationCode.fieldNotAllowedForKind, "wip is ignored for \(s.kind.rawValue) stages",
                                 params: ["field": "wip", "kind": s.kind.rawValue])
                case .merge where w != 1:
                    sink.error("\(p).wip", ValidationCode.wipOutOfRange, "The merge stage always has wip 1", params: range(nil, 1...1))
                default:
                    if !(1...maxWIP).contains(w) {
                        sink.error("\(p).wip", ValidationCode.wipOutOfRange, "wip must be 1…\(maxWIP)", params: range(nil, 1...maxWIP))
                    }
                }
            }

            // Agent
            if s.kind == .agent {
                if let a = s.agent {
                    validateAgent(a, stage: s, path: "\(p).agent", context: context, sink: &sink)
                } else {
                    sink.error("\(p).agent", ValidationCode.agentMissing, "Agent stage '\(s.id)' needs an 'agent' block with an explicit model")
                    sink.error("\(p).agent.model", ValidationCode.modelMissing, "Stage '\(s.id)' has no model; choose an explicit model (auto is not allowed)")
                }
            } else if s.agent != nil {
                sink.error("\(p).agent", ValidationCode.fieldNotAllowedForKind, "Only agent stages can have 'agent'",
                       params: ["field": "agent", "kind": s.kind.rawValue])
            }

            // Gates
            if s.kind == .queue || s.kind == .terminal || s.kind == .human, !s.gates.isEmpty {
                sink.error("\(p).gates", ValidationCode.fieldNotAllowedForKind, "\(s.kind.rawValue) stages cannot have gates",
                           params: ["field": "gates", "kind": s.kind.rawValue])
            }
            if s.kind == .gate && s.gates.isEmpty {
                sink.error("\(p).gates", ValidationCode.missingField, "Gate stage '\(s.id)' needs at least one gate command")
            }

            // Returns
            if !s.returnsTo.isEmpty && s.kind != .agent {
                sink.error("\(p).returns_to", ValidationCode.returnsNotAllowed,
                           "Only agent stages return by returns_to; \(s.kind.rawValue) stages use \(s.kind == .gate ? "on_fail" : s.kind == .merge ? "on_conflict" : "human commands")")
            }
            // v0.11.4 §3.1: the target of any return must be an agent stage with readOnly == false. An explicit target
            // on a read-only stage, or no eligible default, is `no_return_target` (stageId = the stage owning the return).
            func checkReturnTarget(_ t: StageID, _ path: String, what: String) {
                guard ref(t, path) else { return }
                if !c.isUpstream(t, of: s.id) {
                    sink.error(path, ValidationCode.returnsForward, "\(what) of '\(s.id)' must point backwards along on_success, not to '\(t)'")
                }
                guard let target = c.stage(t) else { return }
                if target.kind != .agent {
                    sink.error(path, ValidationCode.noReturnTarget, "\(what) of '\(s.id)' must target an agent stage, '\(t)' is \(target.kind.rawValue)")
                } else if target.isReadOnly {
                    sink.error(path, ValidationCode.noReturnTarget, "\(what) of '\(s.id)' targets read-only stage '\(t)'; a task can only be returned to a writable agent stage")
                }
            }
            var seenTargets = Set<StageID>()
            for (j, r) in s.returnsTo.enumerated() {
                let rp = "\(p).returns_to[\(j)]"
                if !seenTargets.insert(r.stage).inserted {
                    sink.error("\(rp).stage", ValidationCode.duplicateId, "Return target '\(r.stage)' is listed twice", params: ["id": r.stage.rawValue])
                }
                checkReturnTarget(r.stage, "\(rp).stage", what: "returns_to")
                if !(1...100).contains(r.limit) {
                    sink.error("\(rp).limit", ValidationCode.limitOutOfRange, "Return limit must be 1…100", params: range("returns_to.limit", 1...100))
                }
            }
            if s.onFail != nil && s.kind != .gate {
                sink.error("\(p).on_fail", ValidationCode.fieldNotAllowedForKind, "on_fail is only for gate stages",
                       params: ["field": "on_fail", "kind": s.kind.rawValue])
            }
            if s.kind == .gate {
                // The block is optional; a red gate is never retried in place, so a target must always exist.
                if let t = s.onFail?.stage {
                    checkReturnTarget(t, "\(p).on_fail.stage", what: "on_fail")
                } else if c.nearestWritableAgentStage(before: s.id) == nil {
                    sink.error(s.onFail == nil ? "\(p).on_fail" : "\(p).on_fail.stage", ValidationCode.noReturnTarget,
                               "Gate stage '\(s.id)' has no preceding writable agent stage to return to; set on_fail.stage or add one")
                }
                if let f = s.onFail, !(1...100).contains(f.limit) {
                    sink.error("\(p).on_fail.limit", ValidationCode.limitOutOfRange, "on_fail limit must be 1…100", params: range("on_fail.limit", 1...100))
                }
            }
            if s.onConflict != nil && s.kind != .merge {
                sink.error("\(p).on_conflict", ValidationCode.fieldNotAllowedForKind, "on_conflict is only for the merge stage",
                       params: ["field": "on_conflict", "kind": s.kind.rawValue])
            }
            if s.kind == .merge {
                if let t = s.onConflict?.stage {
                    checkReturnTarget(t, "\(p).on_conflict.stage", what: "on_conflict")
                } else if c.defaultReturnStage == nil {
                    sink.error(s.onConflict == nil ? "\(p).on_conflict" : "\(p).on_conflict.stage", ValidationCode.noReturnTarget,
                               "No writable agent stage to send merge conflicts to")
                }
                if let oc = s.onConflict, !(1...100).contains(oc.limit) {
                    sink.error("\(p).on_conflict.limit", ValidationCode.limitOutOfRange, "on_conflict limit must be 1…100", params: range("on_conflict.limit", 1...100))
                }
            }

            // Retry & timeouts (meaningful for agent and gate stages)
            if s.kind == .agent || s.kind == .gate || s.kind == .merge {
                if !(1...maxAttempts).contains(s.retry.maxAttempts) {
                    sink.error("\(p).retry.max_attempts", ValidationCode.attemptsOutOfRange, "max_attempts must be 1…\(maxAttempts)",
                           params: range(nil, 1...maxAttempts))
                } else if s.retry.backoffSeconds.count > s.retry.maxAttempts - 1 {
                    sink.error("\(p).retry.backoff", ValidationCode.backoffTooLong,
                               "backoff has \(s.retry.backoffSeconds.count) pauses; at most max_attempts − 1 = \(s.retry.maxAttempts - 1)",
                               params: ["max": String(s.retry.maxAttempts - 1)])   // a pause COUNT, see report
                }
                for (j, b) in s.retry.backoffSeconds.enumerated() where !(1...maxBackoffSeconds).contains(b) {
                    sink.error("\(p).retry.backoff[\(j)]", ValidationCode.durationOutOfRange, "Each pause must be 1s…1h",
                           params: range("backoff", 1...maxBackoffSeconds, duration: true))
                }
                if !stallRange.contains(s.timeouts.stallSeconds) {
                    sink.error("\(p).timeouts.stall", ValidationCode.durationOutOfRange, "stall timeout must be 1m…2h",
                           params: range("stall", stallRange, duration: true))
                }
                if !wallRange.contains(s.timeouts.wallSeconds) {
                    sink.error("\(p).timeouts.wall", ValidationCode.durationOutOfRange, "wall timeout must be 1m…24h",
                           params: range("wall", wallRange, duration: true))
                } else if s.timeouts.stallSeconds > s.timeouts.wallSeconds {
                    sink.error("\(p).timeouts.stall", ValidationCode.durationOutOfRange, "stall timeout cannot exceed the wall timeout",
                           params: range("stall", stallRange.lowerBound...s.timeouts.wallSeconds, duration: true))
                }
            }

            // Stage git overrides
            if let g = s.git {
                if s.kind != .agent {
                    sink.error("\(p).git", ValidationCode.fieldNotAllowedForKind, "git overrides are only for agent stages",
                           params: ["field": "git", "kind": s.kind.rawValue])
                }
                for (j, r) in g.extend.enumerated() {
                    let path = "\(p).git.extend[\(j)]"
                    checkGitRule(r, path: path, granting: true, sink: &sink)
                    // v0.11.18 §8.4: a read-only stage cannot allow a writing command, with or without `when`.
                    // Hard invariants already got `git_hard_invariant`; empty rules got `invalid_value`; a command outside
                    // `gitCommandCatalog` only gets `git_unknown_command` (v0.11.19, one message per line) and the
                    // resolver lists it as a stage deny.
                    let rule = GitPolicyResolver.normalize(r)
                    if s.isReadOnly, !rule.isEmpty, !GitPolicyResolver.violatesHardInvariant(rule), GitPolicyResolver.isKnown(rule),
                       !GitPolicyResolver.readCommands.contains(where: { GitPolicyResolver.covers($0, rule) }) {
                        let cmd = String(rule.split(separator: " ").first ?? "")
                        // §4.1: {stage} comes from stageId (set by the sink), only {cmd} goes to params.
                        sink.error(path, ValidationCode.gitReadonlyExtend,
                                   "Stage '\(s.id)' is read-only: '\(rule)' cannot be allowed", params: ["cmd": cmd])
                    }
                }
                for (j, r) in g.deny.enumerated() { checkGitRule(r, path: "\(p).git.deny[\(j)]", granting: false, sink: &sink) }
            }
        }

        // v0.11.6 §3.1: `requestChanges` without target needs a writable agent stage — pipeline-level, no `stageId` —
        // but only if `requestChanges` can be called at all (a human, gate or merge stage exists).
        if c.defaultReturnStage == nil && c.stages.contains(where: { [.human, .gate, .merge].contains($0.kind) }) {
            sink.error("stages", ValidationCode.noReturnTarget, "No writable agent stage: requestChanges has no default return target")
        }

        // Graph: terminal reachable from every stage, no on_success cycles.
        for (i, s) in c.stages.enumerated() where s.kind != .terminal {
            var seen = Set<StageID>()
            var cursor: StageID? = s.id
            var outcome: String?
            while let id = cursor {
                if !seen.insert(id).inserted { outcome = ValidationCode.onSuccessCycle; break }
                guard let st = c.stage(id) else { outcome = ValidationCode.unknownStage; break }
                if st.kind == .terminal { break }
                cursor = st.onSuccess
                if cursor == nil { outcome = ValidationCode.terminalUnreachable }
            }
            switch outcome {
            case ValidationCode.onSuccessCycle?:
                sink.error("\(sp(i)).on_success", ValidationCode.onSuccessCycle, "on_success from '\(s.id)' loops without reaching a terminal stage", stageId: s.id)
            case .some:
                sink.error("\(sp(i)).on_success", ValidationCode.terminalUnreachable, "No on_success path from '\(s.id)' to a terminal stage", stageId: s.id)
            case nil: break
            }
        }

        // Stages that still hold tasks cannot disappear.
        let ids = Set(c.stages.map(\.id))
        for removed in context.stagesWithActiveTasks.subtracting(ids).sorted(by: { $0.rawValue < $1.rawValue }) {
            sink.error("stages", ValidationCode.stageHasActiveTasks, "Stage '\(removed)' still has active tasks and cannot be removed", stageId: removed)
        }
        for (index, stage) in c.stages.enumerated() {
            if let oldKind = context.activeStageKinds[stage.id], oldKind != stage.kind {
                sink.error("\(sp(index)).kind", ValidationCode.stageHasActiveTasks, "Stage '\(stage.id)' still has active tasks and cannot change kind", stageId: stage.id)
            }
        }
    }

    static func validateAgent(_ a: AgentConfig, stage s: StageConfig, path p: String, context: PipelineValidationContext, sink: inout IssueSink) {
        if let m = a.model?.rawValue, isAuto(m) {
            sink.error("\(p).model", ValidationCode.modelAutoForbidden, "Stage '\(s.id)' uses 'auto'; Kaban needs an explicit model")
        } else if !hasExplicitModel(a.model) {
            sink.error("\(p).model", ValidationCode.modelMissing, "Stage '\(s.id)' has no model; choose an explicit model (auto is not allowed)")
        }
        if !context.supportedHarnesses.contains(a.harness) {
            sink.error("\(p).harness", ValidationCode.harnessUnsupported,
                       "Harness '\(a.harness)' is not supported; available: \(context.supportedHarnesses.sorted().joined(separator: ", "))",
                       params: ["harness": a.harness])
        }
        for (j, server) in a.mcp.enumerated() where server != AgentConfig.boardMcpServer && !context.mcpAllowlist.contains(server) {
            sink.warning("\(p).mcp[\(j)]", ValidationCode.mcpNotAllowlisted,
                         "MCP server '\(server)' is not enabled in the project allowlist; it will not be connected",
                         params: ["name": server])
        }
        for key in a.env.keys.sorted() {
            let value = a.env[key] ?? ""
            let upper = key.uppercased()
            if secretKeyWords.contains(where: { upper.contains($0) }) || secretValuePrefixes.contains(where: { value.hasPrefix($0) }) {
                sink.error("\(p).env.\(key)", ValidationCode.secretInEnv,
                           "env '\(key)' looks like a secret; secrets are referenced by Keychain key name, never stored in pipeline.yaml",
                           params: ["key": key])
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
            sink.error(path, ValidationCode.invalidValue, "Empty git rule", params: ["value": rule])
            return
        }
        // §4.1: `git_hard_invariant` has no placeholders → empty params; the id is only in `message`.
        if let id = GitPolicyResolver.hardInvariant(for: r) {
            if granting {
                sink.error(path, ValidationCode.gitHardInvariant, "'\(r)' hits hard invariant '\(id)' and cannot be allowed by any policy")
            }
            // Denying a hard invariant is redundant but harmless: no `git_unknown_command` for it.
        } else if !GitPolicyResolver.isKnown(r) {
            // §4.1: "first word of the rule is not in the catalog" — `{cmd}` is that first word.
            let cmd = String(r.split(separator: " ").first ?? "")
            sink.warning(path, ValidationCode.gitUnknownCommand, "Unknown git command '\(cmd)'", params: ["cmd": cmd])
        }
    }
}
