import Foundation
import KabanProtocol

/// Collects `ValidationIssue`s with field paths like `stages[2].wip`.
struct IssueSink {
    var issues: [ValidationIssue] = []
    mutating func error(_ path: String, _ code: String, _ message: String) {
        issues.append(ValidationIssue(path: path, code: code, message: message, severity: .error))
    }
    mutating func warning(_ path: String, _ code: String, _ message: String) {
        issues.append(ValidationIssue(path: path, code: code, message: message, severity: .warning))
    }
}

/// Structural decoding of the YAML tree into `PipelineConfig`. Never throws: every problem becomes an issue.
/// Semantic rules live in `PipelineValidator`.
struct PipelineParser {
    var sink = IssueSink()
    /// For each element of `config.stages`, the index of the stage in the YAML `stages` list (paths must point at the source).
    var stageSourceIndex: [Int] = []

    static func join(_ base: String, _ key: String) -> String { base.isEmpty ? key : "\(base).\(key)" }

    mutating func parse(_ root: YAMLNode) -> PipelineConfig? {
        guard case .mapping(let entries) = root.value else {
            sink.error("", KabanValidationCode.typeMismatch, "pipeline.yaml must be a mapping at the top level (line \(root.line))")
            return nil
        }
        checkKeys(entries, allowed: ["version", "board", "workspace", "git", "suspicious_files", "stages"], path: "")
        var config = PipelineConfig(stages: [])

        if let v = root["version"] {
            if let n = int(v, "version") {
                config.version = n
                if n != 1 { sink.error("version", KabanValidationCode.versionUnsupported, "Unsupported pipeline version \(n); expected 1") }
            }
        } else {
            sink.error("version", KabanValidationCode.missingField, "Field 'version' is required (version: 1)")
        }

        if let b = root["board"], let e = mapping(b, "board") {
            checkKeys(e, allowed: ["max_waiting_human", "bounce_limit_total", "max_runs_per_task"], path: "board")
            if let n = b["max_waiting_human"].flatMap({ int($0, "board.max_waiting_human") }) { config.board.maxWaitingHuman = n }
            if let n = b["bounce_limit_total"].flatMap({ int($0, "board.bounce_limit_total") }) { config.board.bounceLimitTotal = n }
            if let n = b["max_runs_per_task"].flatMap({ int($0, "board.max_runs_per_task") }) { config.board.maxRunsPerTask = n }
        }

        if let w = root["workspace"], let e = mapping(w, "workspace") {
            checkKeys(e, allowed: ["warm_paths", "on_create"], path: "workspace")
            if let l = w["warm_paths"].flatMap({ stringList($0, "workspace.warm_paths") }) { config.workspace.warmPaths = l }
            config.workspace.onCreate = w["on_create"].flatMap { string($0, "workspace.on_create") }
        }

        if let g = root["git"], let e = mapping(g, "git") {
            checkKeys(e, allowed: ["preset", "allow", "deny"], path: "git")
            if let p = g["preset"].flatMap({ string($0, "git.preset") }) {
                if let preset = GitPreset(rawValue: p) { config.git.preset = preset } else {
                    sink.error("git.preset", KabanValidationCode.invalidValue, "Unknown git preset '\(p)'; expected strict, standard or permissive")
                }
            }
            if let l = g["allow"].flatMap({ stringList($0, "git.allow") }) { config.git.allow = l }
            if let l = g["deny"].flatMap({ stringList($0, "git.deny") }) { config.git.deny = l }
        }

        if let s = root["suspicious_files"], let e = mapping(s, "suspicious_files") {
            checkKeys(e, allowed: ["patterns", "max_file_mb", "allow"], path: "suspicious_files")
            if let l = s["patterns"].flatMap({ stringList($0, "suspicious_files.patterns") }) { config.suspiciousFiles.patterns = l }
            if let d = s["max_file_mb"].flatMap({ double($0, "suspicious_files.max_file_mb") }) { config.suspiciousFiles.maxFileMB = d }
            if let l = s["allow"].flatMap({ stringList($0, "suspicious_files.allow") }) { config.suspiciousFiles.allow = l }
        }

        if let st = root["stages"] {
            if case .sequence(let items) = st.value {
                for (i, item) in items.enumerated() {
                    if let stage = parseStage(item, index: i) {
                        config.stages.append(stage)
                        stageSourceIndex.append(i)
                    }
                }
            } else if !st.isNull {
                sink.error("stages", KabanValidationCode.typeMismatch, "'stages' must be a list (line \(st.line))")
            }
        } else {
            sink.error("stages", KabanValidationCode.missingField, "Field 'stages' is required")
        }
        return config
    }

    static let stageKeys: Set<String> = ["id", "name", "kind", "display", "wip", "priority", "agent", "git", "inputs", "gates",
                                         "on_success", "returns_to", "on_fail", "on_conflict", "retry", "timeouts", "hooks", "notify"]

    mutating func parseStage(_ node: YAMLNode, index i: Int) -> StageConfig? {
        let p = "stages[\(i)]"
        guard let entries = mapping(node, p) else { return nil }
        checkKeys(entries, allowed: Self.stageKeys, path: p)
        guard let id = node["id"].flatMap({ string($0, "\(p).id") }) else {
            sink.error("\(p).id", KabanValidationCode.missingField, "Stage at line \(node.line) has no 'id'")
            return nil
        }
        guard let kindText = node["kind"].flatMap({ string($0, "\(p).kind") }) else {
            sink.error("\(p).kind", KabanValidationCode.missingField, "Stage '\(id)' has no 'kind'")
            return nil
        }
        guard let kind = StageKind(rawValue: kindText) else {
            sink.error("\(p).kind", KabanValidationCode.invalidValue,
                       "Stage '\(id)': unknown kind '\(kindText)'; expected one of \(StageKind.allCases.map(\.rawValue).joined(separator: ", "))")
            return nil
        }
        var stage = StageConfig(id: StageID(rawValue: id), kind: kind, display: StageDisplay(order: i))
        if let name = node["name"].flatMap({ string($0, "\(p).name") }) { stage.name = name }

        if let d = node["display"], let e = mapping(d, "\(p).display") {
            checkKeys(e, allowed: ["icon", "color", "order", "collapsed", "hidden"], path: "\(p).display")
            stage.display.icon = d["icon"].flatMap { string($0, "\(p).display.icon") }
            stage.display.color = d["color"].flatMap { string($0, "\(p).display.color") }
            if let o = d["order"].flatMap({ int($0, "\(p).display.order") }) { stage.display.order = o }
            if let c = d["collapsed"].flatMap({ bool($0, "\(p).display.collapsed") }) { stage.display.collapsed = c }
            if let h = d["hidden"].flatMap({ bool($0, "\(p).display.hidden") }) { stage.display.hidden = h }
        }
        stage.wip = node["wip"].flatMap { int($0, "\(p).wip") }
        if let pr = node["priority"].flatMap({ stringList($0, "\(p).priority") }) {
            var rules: [PriorityRule] = []
            for (j, r) in pr.enumerated() {
                if let rule = PriorityRule(rawValue: r) { rules.append(rule) } else {
                    sink.error("\(p).priority[\(j)]", KabanValidationCode.invalidValue, "Unknown priority rule '\(r)'; expected returned, answered or fifo")
                }
            }
            stage.priority = rules
        }
        if let a = node["agent"], !a.isNull { stage.agent = parseAgent(a, path: "\(p).agent") }
        if let g = node["git"], !g.isNull { stage.git = parseStageGit(g, path: "\(p).git") }
        if let l = node["inputs"].flatMap({ stringList($0, "\(p).inputs") }) { stage.inputs = l }
        if let l = node["gates"].flatMap({ stringList($0, "\(p).gates") }) { stage.gates = l }
        stage.onSuccess = node["on_success"].flatMap { string($0, "\(p).on_success") }.map(StageID.init(rawValue:))
        if let r = node["returns_to"], !r.isNull {
            if case .sequence(let items) = r.value {
                stage.returnsTo = items.enumerated().compactMap { j, item in parseReturn(item, path: "\(p).returns_to[\(j)]", limitRequired: true) }
            } else {
                sink.error("\(p).returns_to", KabanValidationCode.typeMismatch, "'returns_to' must be a list of { stage, limit }")
            }
        }
        if let f = node["on_fail"], !f.isNull { stage.onFail = parseReturn(f, path: "\(p).on_fail", limitRequired: true) }
        if let c = node["on_conflict"], !c.isNull, let e = mapping(c, "\(p).on_conflict") {
            checkKeys(e, allowed: ["stage", "limit"], path: "\(p).on_conflict")
            var cr = ConflictReturn()
            cr.stage = c["stage"].flatMap { string($0, "\(p).on_conflict.stage") }.map(StageID.init(rawValue:))
            if let l = c["limit"].flatMap({ int($0, "\(p).on_conflict.limit") }) { cr.limit = l }
            stage.onConflict = cr
        }
        if let r = node["retry"], !r.isNull, let e = mapping(r, "\(p).retry") {
            checkKeys(e, allowed: ["max_attempts", "backoff"], path: "\(p).retry")
            if let m = r["max_attempts"].flatMap({ int($0, "\(p).retry.max_attempts") }) { stage.retry.maxAttempts = m }
            if let b = r["backoff"], let list = stringList(b, "\(p).retry.backoff") {
                var secs: [Int] = []
                for (j, item) in list.enumerated() {
                    if let s = DurationParser.seconds(item) { secs.append(s) } else {
                        sink.error("\(p).retry.backoff[\(j)]", KabanValidationCode.invalidValue, "Invalid duration '\(item)' (use 30s, 2m, 1h)")
                    }
                }
                stage.retry.backoffSeconds = secs
            }
        }
        if let t = node["timeouts"], !t.isNull, let e = mapping(t, "\(p).timeouts") {
            checkKeys(e, allowed: ["stall", "wall"], path: "\(p).timeouts")
            if let s = t["stall"].flatMap({ duration($0, "\(p).timeouts.stall") }) { stage.timeouts.stallSeconds = s }
            if let w = t["wall"].flatMap({ duration($0, "\(p).timeouts.wall") }) { stage.timeouts.wallSeconds = w }
        }
        if let h = node["hooks"], !h.isNull, let e = mapping(h, "\(p).hooks") {
            checkKeys(e, allowed: ["on_enter", "on_exit"], path: "\(p).hooks")
            stage.hooks.onEnter = h["on_enter"].flatMap { string($0, "\(p).hooks.on_enter") }
            stage.hooks.onExit = h["on_exit"].flatMap { string($0, "\(p).hooks.on_exit") }
        }
        if let l = node["notify"].flatMap({ stringList($0, "\(p).notify") }) { stage.notify = l }
        return stage
    }

    mutating func parseAgent(_ node: YAMLNode, path p: String) -> AgentConfig? {
        guard let e = mapping(node, p) else { return nil }
        checkKeys(e, allowed: ["harness", "model", "skill", "permissions", "mcp", "env", "workspace"], path: p)
        var agent = AgentConfig(model: nil)
        if let h = node["harness"].flatMap({ string($0, "\(p).harness") }) { agent.harness = h }
        agent.model = node["model"].flatMap { string($0, "\(p).model") }.map(ModelID.init(rawValue:))
        agent.skill = node["skill"].flatMap { string($0, "\(p).skill") }
        if let perm = node["permissions"].flatMap({ string($0, "\(p).permissions") }) {
            if let v = AgentPermissions(rawValue: perm) { agent.permissions = v } else {
                sink.error("\(p).permissions", KabanValidationCode.invalidValue, "Unknown permissions '\(perm)'; expected write or read-only")
            }
        }
        if let m = node["mcp"].flatMap({ stringList($0, "\(p).mcp") }) { agent.mcp = m }
        if let env = node["env"], !env.isNull, let entries = mapping(env, "\(p).env") {
            var out: [String: String] = [:]
            for entry in entries {
                if let v = string(entry.value, "\(p).env.\(entry.key)") { out[entry.key] = v }
            }
            agent.env = out
        }
        if let w = node["workspace"].flatMap({ string($0, "\(p).workspace") }) {
            if let v = AgentWorkspaceMode(rawValue: w) { agent.workspace = v } else {
                sink.error("\(p).workspace", KabanValidationCode.invalidValue, "Unknown workspace '\(w)'; expected task or fresh-readonly")
            }
        }
        return agent
    }

    mutating func parseStageGit(_ node: YAMLNode, path p: String) -> StageGitOverride? {
        guard let e = mapping(node, p) else { return nil }
        checkKeys(e, allowed: ["extend", "deny", "when"], path: p)
        var o = StageGitOverride()
        if let l = node["extend"].flatMap({ stringList($0, "\(p).extend") }) { o.extend = l }
        if let l = node["deny"].flatMap({ stringList($0, "\(p).deny") }) { o.deny = l }
        if let w = node["when"].flatMap({ string($0, "\(p).when") }) {
            if let c = GitOverrideCondition.parse(w) { o.when = c } else {
                sink.error("\(p).when", KabanValidationCode.gitConditionInvalid,
                           "Unsupported condition '\(w)'; expected 'return_reason == <\(ReturnReason.allCases.map(\.rawValue).joined(separator: "|"))>'")
            }
        }
        return o
    }

    mutating func parseReturn(_ node: YAMLNode, path p: String, limitRequired: Bool) -> StageReturn? {
        guard let e = mapping(node, p) else { return nil }
        checkKeys(e, allowed: ["stage", "limit"], path: p)
        guard let s = node["stage"].flatMap({ string($0, "\(p).stage") }) else {
            sink.error("\(p).stage", KabanValidationCode.missingField, "Return target needs 'stage'")
            return nil
        }
        guard let l = node["limit"].flatMap({ int($0, "\(p).limit") }) else {
            sink.error("\(p).limit", KabanValidationCode.missingField, "Return to '\(s)' needs an explicit 'limit'")
            return nil
        }
        return StageReturn(stage: StageID(rawValue: s), limit: l)
    }

    // MARK: Primitive readers

    mutating func checkKeys(_ entries: [YAMLEntry], allowed: Set<String>, path: String) {
        for e in entries where !allowed.contains(e.key) {
            sink.warning(Self.join(path, e.key), KabanValidationCode.unknownKey, "Unknown key '\(e.key)' (line \(e.keyLine)) is ignored")
        }
    }

    mutating func mapping(_ node: YAMLNode, _ path: String) -> [YAMLEntry]? {
        if case .mapping(let e) = node.value { return e }
        if node.isNull { return nil }
        sink.error(path, KabanValidationCode.typeMismatch, "Expected a mapping (line \(node.line))")
        return nil
    }

    /// Scalar as text; plain `null`/`~`/empty is treated as absent.
    mutating func string(_ node: YAMLNode, _ path: String) -> String? {
        switch node.value {
        case .scalar(let s, _): return node.isNull ? nil : s
        default:
            sink.error(path, KabanValidationCode.typeMismatch, "Expected a single value (line \(node.line))")
            return nil
        }
    }

    mutating func int(_ node: YAMLNode, _ path: String) -> Int? {
        guard let s = string(node, path) else { return nil }
        if case .scalar(_, let quoted) = node.value, !quoted, let n = Int(s) { return n }
        sink.error(path, KabanValidationCode.typeMismatch, "Expected an integer, got '\(s)' (line \(node.line))")
        return nil
    }

    mutating func double(_ node: YAMLNode, _ path: String) -> Double? {
        guard let s = string(node, path) else { return nil }
        if case .scalar(_, let quoted) = node.value, !quoted, let n = Double(s), n.isFinite { return n }
        sink.error(path, KabanValidationCode.typeMismatch, "Expected a number, got '\(s)' (line \(node.line))")
        return nil
    }

    mutating func bool(_ node: YAMLNode, _ path: String) -> Bool? {
        guard let s = string(node, path) else { return nil }
        if case .scalar(_, let quoted) = node.value, !quoted {
            switch s { case "true", "True", "TRUE", "yes": return true; case "false", "False", "FALSE", "no": return false; default: break }
        }
        sink.error(path, KabanValidationCode.typeMismatch, "Expected true or false, got '\(s)' (line \(node.line))")
        return nil
    }

    mutating func duration(_ node: YAMLNode, _ path: String) -> Int? {
        guard let s = string(node, path) else { return nil }
        if let v = DurationParser.seconds(s) { return v }
        sink.error(path, KabanValidationCode.invalidValue, "Invalid duration '\(s)' (use 30s, 10m, 1h)")
        return nil
    }

    /// A list of scalars. A single scalar is not promoted to a list.
    mutating func stringList(_ node: YAMLNode, _ path: String) -> [String]? {
        if node.isNull { return [] }
        guard case .sequence(let items) = node.value else {
            sink.error(path, KabanValidationCode.typeMismatch, "Expected a list (line \(node.line))")
            return nil
        }
        var out: [String] = []
        for (i, item) in items.enumerated() {
            if let s = string(item, "\(path)[\(i)]") { out.append(s) }
        }
        return out
    }
}
