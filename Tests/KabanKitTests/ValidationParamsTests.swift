import Foundation
import XCTest
import KabanProtocol
@testable import KabanKit

/// `ValidationIssue.params` (arch. v0.11.18, spec v0.8.18 §4.1): placeholders of the UI text, except `{stage}` (from
/// `stageId`) and `{path}` (from `path`). Severity alone decides error vs warning.
final class ValidationParamsTests: XCTestCase {
    /// Keys each code's §4.1 text needs from `params`.
    static let required: [String: Set<String>] = [
        ValidationCode.yamlSyntax: ["line"], ValidationCode.versionUnsupported: ["n"], ValidationCode.invalidValue: ["value"],
        ValidationCode.unknownKey: ["key"], ValidationCode.duplicateId: ["id"], ValidationCode.unknownStage: ["id"],
        ValidationCode.queueCount: ["n"], ValidationCode.mergeCount: ["n"], ValidationCode.fieldNotAllowedForKind: ["field", "kind"],
        ValidationCode.harnessUnsupported: ["harness"], ValidationCode.wipOutOfRange: ["min", "max"],
        ValidationCode.limitOutOfRange: ["label", "min", "max"], ValidationCode.attemptsOutOfRange: ["min", "max"],
        ValidationCode.durationOutOfRange: ["label", "min", "max"], ValidationCode.backoffTooLong: ["max"],
        ValidationCode.secretInEnv: ["key"], ValidationCode.mcpNotAllowlisted: ["name"], ValidationCode.gitConditionInvalid: ["when"],
        ValidationCode.gitUnknownCommand: ["cmd"], ValidationCode.gitReadonlyExtend: ["cmd"],
    ]
    static let allowedKeys: Set<String> = ["line", "n", "value", "key", "id", "field", "kind", "harness", "min", "max", "label",
                                           "name", "when", "cmd"]
    /// The four codes that come as warnings (§4.1 ⚠); `field_not_allowed_for_kind` only for `wip`.
    static func expectedSeverity(_ i: ValidationIssue) -> ValidationIssue.Severity {
        switch i.code {
        case ValidationCode.unknownKey, ValidationCode.mcpNotAllowlisted, ValidationCode.gitUnknownCommand: .warning
        case ValidationCode.fieldNotAllowedForKind where i.params["field"] == "wip": .warning
        default: .error
        }
    }

    static let badPipelines: [String] = [
        "version: 1\nstages: [\n  - { id: x",
        "version: 2\nstages: []\n",
        """
        version: 1
        board: { max_waiting_human: 0, bounce_limit_total: 101, max_runs_per_task: 0 }
        git: { preset: loose, allow: [push, frobnicate] }
        suspicious_files: { max_file_mb: 0 }
        stages:
          - { id: backlog, kind: queue, on_success: dev, wip: 2 }
          - { id: backlog, kind: queue, on_success: dev }
          - id: dev
            kind: agent
            wip: 99
            bogus: 1
            priority: [soonest]
            agent: { model: m1, harness: claude-code, permissions: admin, mcp: [kaban, linear], env: { API_TOKEN: x } }
            git: { extend: [rebase], when: branch == main }
            retry: { max_attempts: 2, backoff: [30s, 2m, 5m] }
            timeouts: { stall: 3h, wall: 30m }
            returns_to: [{ stage: ghost, limit: 0 }]
            on_success: check
          - { id: check, kind: gate, gates: [make], on_fail: { limit: 500 }, retry: { max_attempts: 11, backoff: [2h] }, on_success: human }
          - { id: human, kind: human, gates: [x], agent: { model: m1 }, on_success: merge }
          - { id: merge, kind: merge, wip: 2, on_conflict: { limit: 0 }, timeouts: { stall: 10s, wall: 30h }, on_success: done }
          - { id: merge2, kind: merge, on_success: done, git: { extend: [stash] } }
          - { id: done, kind: terminal, wip: 1, on_success: dev }
        """,
        """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: dev }
          - { id: dev, kind: agent, agent: { model: m1, workspace: shared }, timeouts: { stall: 2h, wall: 1h }, retry: { backoff: [soon] }, on_success: weird }
          - { id: weird, kind: sideways, on_success: done }
          - { id: done, kind: terminal }
        """,
    ]

    func allIssues() throws -> [ValidationIssue] {
        var texts = Self.badPipelines + [GitPolicyTests.readOnlyExtendYAML]
        for f in ["bad-semantics.yaml", "bad-structure.yaml", "bad-syntax.yaml", "good-full.yaml"] { texts.append(try Fixtures.text(f)) }
        return texts.flatMap { PipelineValidator.validate(yaml: $0, context: .init(mcpAllowlist: ["github"])).issues }
    }

    func testEveryIssueCarriesTheKeysOfItsUIText() throws {
        let issues = try allIssues()
        let seen = Set(issues.map(\.code))
        // The sample covers every code that has params placeholders.
        XCTAssertEqual(Set(Self.required.keys).subtracting(seen), [], "codes not exercised")
        for i in issues {
            let label = "\(i.code) at \(i.path): \(i.message) params=\(i.params)"
            XCTAssertNil(i.params["stage"], label); XCTAssertNil(i.params["path"], label)
            XCTAssertTrue(Set(i.params.keys).isSubset(of: Self.allowedKeys), label)
            var need = Self.required[i.code] ?? []
            // Known gap: max_file_mb has no upper bound, so no {min}/{max}; the UI falls back to `message`.
            if i.code == ValidationCode.limitOutOfRange && i.path == "suspicious_files.max_file_mb" { need = ["label"] }
            XCTAssertTrue(need.isSubset(of: Set(i.params.keys)), "missing \(need.subtracting(i.params.keys)) — \(label)")
            XCTAssertEqual(i.severity, Self.expectedSeverity(i), label)
        }
    }

    func testRepresentativeParams() throws {
        let v = PipelineValidator.validate(yaml: Self.badPipelines[2], context: .init(mcpAllowlist: []))
        func issue(_ code: String, _ path: String) -> ValidationIssue? { v.issues.first { $0.code == code && $0.path == path } }
        XCTAssertEqual(issue(ValidationCode.invalidValue, "git.preset")?.params, ["value": "loose"])
        XCTAssertEqual(issue(ValidationCode.duplicateId, "stages[1].id")?.params, ["id": "backlog"])
        XCTAssertEqual(issue(ValidationCode.duplicateId, "stages[1].id")?.stageId, "backlog")
        XCTAssertEqual(issue(ValidationCode.unknownStage, "stages[2].returns_to[0].stage")?.params, ["id": "ghost"])
        XCTAssertEqual(issue(ValidationCode.queueCount, "stages[1].kind")?.params, ["n": "2"])
        XCTAssertEqual(issue(ValidationCode.mergeCount, "stages[6].kind")?.params, ["n": "2"])
        let unknownKey = try XCTUnwrap(issue(ValidationCode.unknownKey, "stages[2].bogus"))
        XCTAssertEqual(unknownKey.params, ["key": "bogus", "line": "11"])
        XCTAssertEqual(unknownKey.severity, .warning)
        XCTAssertEqual(unknownKey.stageId, "dev")
        XCTAssertEqual(issue(ValidationCode.wipOutOfRange, "stages[2].wip")?.params, ["min": "1", "max": "\(PipelineValidator.maxWIP)"])
        XCTAssertEqual(issue(ValidationCode.wipOutOfRange, "stages[5].wip")?.params, ["min": "1", "max": "1"])
        let wipQueue = try XCTUnwrap(issue(ValidationCode.fieldNotAllowedForKind, "stages[0].wip"))
        XCTAssertEqual(wipQueue.params, ["field": "wip", "kind": "queue"]); XCTAssertEqual(wipQueue.severity, .warning)
        let gatesHuman = try XCTUnwrap(issue(ValidationCode.fieldNotAllowedForKind, "stages[4].gates"))
        XCTAssertEqual(gatesHuman.params, ["field": "gates", "kind": "human"]); XCTAssertEqual(gatesHuman.severity, .error)
        XCTAssertEqual(issue(ValidationCode.limitOutOfRange, "board.bounce_limit_total")?.params,
                       ["label": "bounce_limit_total", "min": "0", "max": "100"])
        XCTAssertEqual(issue(ValidationCode.limitOutOfRange, "stages[3].on_fail.limit")?.params, ["label": "on_fail.limit", "min": "1", "max": "100"])
        XCTAssertEqual(issue(ValidationCode.limitOutOfRange, "stages[5].on_conflict.limit")?.params, ["label": "on_conflict.limit", "min": "1", "max": "100"])
        XCTAssertEqual(issue(ValidationCode.attemptsOutOfRange, "stages[3].retry.max_attempts")?.params, ["min": "1", "max": "10"])
        XCTAssertEqual(issue(ValidationCode.durationOutOfRange, "stages[3].retry.backoff[0]")?.params, ["label": "backoff", "min": "1s", "max": "1h"])
        XCTAssertEqual(issue(ValidationCode.durationOutOfRange, "stages[2].timeouts.stall")?.params, ["label": "stall", "min": "1m", "max": "2h"])
        XCTAssertEqual(issue(ValidationCode.durationOutOfRange, "stages[5].timeouts.wall")?.params, ["label": "wall", "min": "1m", "max": "24h"])
        XCTAssertEqual(issue(ValidationCode.backoffTooLong, "stages[2].retry.backoff")?.params, ["max": "1"])
        XCTAssertEqual(issue(ValidationCode.harnessUnsupported, "stages[2].agent.harness")?.params, ["harness": "claude-code"])
        XCTAssertEqual(issue(ValidationCode.invalidValue, "stages[2].agent.permissions")?.params, ["value": "admin"])
        XCTAssertEqual(issue(ValidationCode.invalidValue, "stages[2].priority[0]")?.params, ["value": "soonest"])
        XCTAssertEqual(issue(ValidationCode.secretInEnv, "stages[2].agent.env.API_TOKEN")?.params, ["key": "API_TOKEN"])
        let mcp = try XCTUnwrap(issue(ValidationCode.mcpNotAllowlisted, "stages[2].agent.mcp[1]"))
        XCTAssertEqual(mcp.params, ["name": "linear"]); XCTAssertEqual(mcp.severity, .warning)
        XCTAssertEqual(issue(ValidationCode.gitConditionInvalid, "stages[2].git.when")?.params, ["when": "branch == main"])
        let unknownCmd = try XCTUnwrap(issue(ValidationCode.gitUnknownCommand, "git.allow[1]"))
        XCTAssertEqual(unknownCmd.params, ["cmd": "frobnicate"]); XCTAssertEqual(unknownCmd.severity, .warning)
        XCTAssertEqual(issue(ValidationCode.gitHardInvariant, "git.allow[0]")?.params, [:], "§4.1 text has no placeholders")

        XCTAssertEqual(PipelineValidator.validate(yaml: Self.badPipelines[0]).issues.first?.params["line"].flatMap(Int.init).map { $0 > 0 }, true)
        XCTAssertEqual(PipelineValidator.validate(yaml: Self.badPipelines[1]).issues.first { $0.code == ValidationCode.versionUnsupported }?.params, ["n": "2"])
        let other = PipelineValidator.validate(yaml: Self.badPipelines[3])
        XCTAssertEqual(other.issues.first { $0.path == "stages[2].kind" }?.params, ["value": "sideways"])
        XCTAssertEqual(other.issues.first { $0.path == "stages[1].agent.workspace" }?.params, ["value": "shared"])
        XCTAssertEqual(other.issues.first { $0.path == "stages[1].retry.backoff[0]" }?.params, ["value": "soon"])
        // {stage}-only texts: nothing in params, the stage comes from stageId.
        let unreachable = try XCTUnwrap(other.issues.first { $0.code == ValidationCode.terminalUnreachable && $0.stageId == "dev" }, other.dump)
        XCTAssertEqual(unreachable.params, [:])
        // stall > wall: the range is 1m … the configured wall.
        XCTAssertEqual(other.issues.first { $0.code == ValidationCode.durationOutOfRange && $0.path == "stages[1].timeouts.stall" }?.params,
                       ["label": "stall", "min": "1m", "max": "1h"])
    }

    /// `{path}`-only texts (`type_mismatch`, `missing_field`) carry no params; `yaml_syntax` carries the exact line.
    func testPathOnlyCodesAndYAMLLine() throws {
        let v = PipelineValidator.validate(yaml: """
        version: 1
        board: [1, 2]
        stages:
          - { id: backlog, kind: queue, on_success: dev }
          - { kind: agent, agent: { model: m1 }, on_success: done }
          - { id: done, kind: terminal }
        """)
        let mismatch = try XCTUnwrap(v.issues.first { $0.code == ValidationCode.typeMismatch }, v.dump)
        XCTAssertEqual(mismatch.path, "board"); XCTAssertEqual(mismatch.params, [:])
        let missing = try XCTUnwrap(v.issues.first { $0.code == ValidationCode.missingField }, v.dump)
        XCTAssertEqual(missing.path, "stages[1].id"); XCTAssertEqual(missing.params, [:])

        let syntax = PipelineValidator.validate(yaml: "version: 1\nstages:\n  - id: a\n    kind: [agent\n")
        let y = try XCTUnwrap(syntax.issues.first, syntax.dump)
        XCTAssertEqual(y.code, ValidationCode.yamlSyntax)
        XCTAssertEqual(y.params.keys.sorted(), ["line"])
        XCTAssertEqual(y.params["line"], "4", syntax.dump)
        XCTAssertNil(syntax.config)

        // max_waiting_human: label is the YAML field name, range 1…100.
        let b = PipelineValidator.validate(yaml: Self.badPipelines[2])
        XCTAssertEqual(b.issues.first { $0.path == "board.max_waiting_human" }?.params, ["label": "max_waiting_human", "min": "1", "max": "100"])
        XCTAssertEqual(b.issues.first { $0.path == "suspicious_files.max_file_mb" }?.params, ["label": "max_file_mb"])
    }

    func testParamsRoundTripThroughJSON() throws {
        let v = PipelineValidator.validate(yaml: Self.badPipelines[1])
        let data = try KabanCoding.makeEncoder().encode(v.issues)
        XCTAssertEqual(try KabanCoding.makeDecoder().decode([ValidationIssue].self, from: data), v.issues)
    }
}
