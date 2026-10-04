import Foundation
import XCTest
import KabanProtocol
@testable import KabanKit

final class PipelineValidatorTests: XCTestCase {
    func testGoodFullPipelineIsValid() throws {
        let v = PipelineValidator.validate(yaml: try Fixtures.text("good-full.yaml"),
                                           context: .init(mcpAllowlist: ["github"]))
        XCTAssertTrue(v.isValid, v.dump)
        XCTAssertTrue(v.issues.isEmpty, v.dump)
        let c = try XCTUnwrap(v.config)
        XCTAssertEqual(c.stages.map(\.id.rawValue), ["backlog", "dev", "test", "lint", "ai_review", "human_review", "merge", "done"])
        let dev = try XCTUnwrap(c.stage("dev"))
        XCTAssertEqual(dev.name, "Разработка")
        XCTAssertEqual(dev.agent?.model, "composer-2")
        XCTAssertEqual(dev.agent?.env, ["NODE_ENV": "test", "LOG_LEVEL": "debug"])
        XCTAssertEqual(dev.retry, RetryPolicy(maxAttempts: 3, backoffSeconds: [30, 120]))
        XCTAssertEqual(dev.timeouts, StageTimeouts(stallSeconds: 600, wallSeconds: 3600))
        XCTAssertEqual(dev.git?.when?.returnReason, .mergeConflict)
        XCTAssertEqual(dev.display, StageDisplay(icon: "hammer", color: "blue", order: 2))
        XCTAssertEqual(dev.gates, ["./gradlew build", "./gradlew test"])
        XCTAssertNil(dev.hooks.onEnter)
        XCTAssertEqual(c.workspace, WorkspaceSettings(warmPaths: ["node_modules", ".gradle"], onCreate: "npm ci --prefer-offline"))
        XCTAssertEqual(c.stage("test")?.returnsTo, [StageReturn(stage: "dev", limit: 3)])
        XCTAssertEqual(c.stage("test")?.retry, RetryPolicy())   // defaults: 3 attempts, [30s, 2m]
        XCTAssertEqual(c.stage("lint")?.onFail, FailReturn(stage: "dev", limit: 2))
        XCTAssertEqual(c.stage("lint")?.failReturn(in: c), StageReturn(stage: "dev", limit: 2))
        XCTAssertEqual(c.stage("ai_review")?.isReadOnly, true)
        XCTAssertEqual(c.stage("merge")?.conflictReturn(in: c), StageReturn(stage: "dev", limit: 2))
        XCTAssertEqual(c.board, BoardSettings())
        XCTAssertEqual(c.firstAgentStage?.id, "dev")
        XCTAssertNil(v.schedulerFlag(projectId: "p"))
    }

    func testDefaultsWhenSectionsAreOmitted() throws {
        let c = TestPipelines.base
        XCTAssertEqual(c.board.maxRunsPerTask, 12)
        XCTAssertEqual(c.board.bounceLimitTotal, 5)
        XCTAssertEqual(c.git.preset, .standard)
        XCTAssertEqual(c.suspiciousFiles, SuspiciousFilesPolicy())
        XCTAssertEqual(c.stage("dev")?.retry.backoffSeconds, [30, 120])
        XCTAssertEqual(c.stage("merge")?.effectiveWIP, 1)
        XCTAssertNil(c.stage("backlog")?.effectiveWIP)
    }

    func testTemplateHasNoDefaultModelsAndIsInvalid() {
        let v = PipelineValidator.validate(yaml: PipelineTemplate.defaultYAML)
        XCTAssertFalse(v.isValid)
        XCTAssertEqual(Set(v.errors.map(\.code)), [ValidationCode.modelMissing], v.dump)
        XCTAssertEqual(v.stagesNeedingModel, ["dev", "test", "ai-review"])
        guard case .projectUnavailable(let p, .pipelineInvalid, let detail)? = v.schedulerFlag(projectId: "p-1") else {
            return XCTFail("expected pipeline_invalid flag")
        }
        XCTAssertEqual(p, "p-1")
        XCTAssertEqual(detail, "stages without an explicit model: dev, test, ai-review")
    }

    func testFillingModelsMakesTemplateValid() {
        let filled = PipelineTemplate.defaultYAML.replacingOccurrences(of: "model:", with: "model: composer-2")
        let v = PipelineValidator.validate(yaml: filled)
        XCTAssertTrue(v.isValid, v.dump)
    }

    func testOneStageWithoutModelInvalidatesWholePipeline() {
        let yaml = TestPipelines.baseYAML.replacingOccurrences(of: "agent: { model: composer-2, permissions: read-only }",
                                                                with: "agent: { permissions: read-only }")
        let v = PipelineValidator.validate(yaml: yaml)
        XCTAssertFalse(v.isValid)
        XCTAssertTrue(v.has(ValidationCode.modelMissing, at: "stages[3].agent.model"), v.dump)
        XCTAssertEqual(v.errors.count, 1, v.dump)
        XCTAssertEqual(v.stagesNeedingModel, ["ai_review"])
    }

    func testPlaceholderModelCountsAsMissing() {
        let yaml = TestPipelines.baseYAML.replacingOccurrences(of: "agent: { model: composer-2 }\n    on_success: test",
                                                                with: "agent: { model: <model-id> }\n    on_success: test")
        let v = PipelineValidator.validate(yaml: yaml)
        XCTAssertTrue(v.has(ValidationCode.modelMissing, at: "stages[1].agent.model"), v.dump)
    }

    func testBadSemantics() throws {
        let v = PipelineValidator.validate(yaml: try Fixtures.text("bad-semantics.yaml"))
        XCTAssertFalse(v.isValid)
        let expected: [(String, String)] = [
            (ValidationCode.limitOutOfRange, "board.max_runs_per_task"),
            (ValidationCode.gitHardInvariant, "git.allow[0]"),
            (ValidationCode.gitHardInvariant, "git.allow[1]"),
            (ValidationCode.wipOutOfRange, "stages[1].wip"),
            (ValidationCode.modelAutoForbidden, "stages[1].agent.model"),
            (ValidationCode.secretInEnv, "stages[1].agent.env.GITHUB_TOKEN"),
            (ValidationCode.secretInEnv, "stages[1].agent.env.OTHER"),
            (ValidationCode.backoffTooLong, "stages[1].retry.backoff"),
            (ValidationCode.modelMissing, "stages[2].agent.model"),
            (ValidationCode.returnsForward, "stages[2].returns_to[0].stage"),
            (ValidationCode.agentMissing, "stages[3].agent"),
            (ValidationCode.modelMissing, "stages[3].agent.model"),
            (ValidationCode.duplicateId, "stages[5].id"),
            (ValidationCode.onSuccessCycle, "stages[2].on_success"),
        ]
        for (code, path) in expected {
            XCTAssertTrue(v.has(code, at: path), "missing \(code) at \(path)\n\(v.dump)")
        }
        XCTAssertEqual(v.stagesNeedingModel, ["dev", "test", "review"])
    }

    func testStructuralErrorsAreIssuesNotThrows() throws {
        let v = PipelineValidator.validate(yaml: try Fixtures.text("bad-structure.yaml"))
        XCTAssertFalse(v.isValid)
        XCTAssertTrue(v.has(ValidationCode.versionUnsupported, at: "version"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.typeMismatch, at: "board.max_runs_per_task"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.unknownKey, at: "mcp", .warning), v.dump)
        XCTAssertTrue(v.has(ValidationCode.invalidValue, at: "stages[1].kind"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.missingField, at: "stages[2].id"), v.dump)
        // backlog → dev is dangling because `dev` was dropped for its invalid kind.
        XCTAssertTrue(v.has(ValidationCode.unknownStage, at: "stages[0].on_success"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.mergeCount, at: "stages"), v.dump)
    }

    func testSyntaxErrorHasLine() throws {
        let v = PipelineValidator.validate(yaml: try Fixtures.text("bad-syntax.yaml"))
        XCTAssertNil(v.config)
        XCTAssertEqual(v.issues.count, 1)
        XCTAssertEqual(v.issues.first?.code, ValidationCode.yamlSyntax)
        XCTAssertTrue(v.issues.first?.message.hasPrefix("line 5:") ?? false, v.dump)
    }

    func testMcpOutsideAllowlistIsOnlyAWarning() {
        // Scenario M1-PIPE-02 (second half): test.mcp = [github] with an empty allowlist.
        let yaml = TestPipelines.baseYAML.replacingOccurrences(of: "agent: { model: composer-2 }\n    returns_to",
                                                                with: "agent: { model: composer-2, mcp: [kaban, github] }\n    returns_to")
        let v = PipelineValidator.validate(yaml: yaml)
        XCTAssertTrue(v.isValid, v.dump)
        XCTAssertTrue(v.has(ValidationCode.mcpNotAllowlisted, at: "stages[2].agent.mcp[1]", .warning), v.dump)
        let allowed = PipelineValidator.validate(yaml: yaml, context: .init(mcpAllowlist: ["github"]))
        XCTAssertTrue(allowed.issues.isEmpty, allowed.dump)
    }

    func testAutoModelAndMcpWarningTogether_PIPE02() {
        let yaml = TestPipelines.baseYAML
            .replacingOccurrences(of: "agent: { model: composer-2 }\n    on_success: test", with: "agent: { model: auto }\n    on_success: test")
            .replacingOccurrences(of: "agent: { model: composer-2 }\n    returns_to", with: "agent: { model: composer-2, mcp: [github] }\n    returns_to")
        let v = PipelineValidator.validate(yaml: yaml)
        XCTAssertFalse(v.isValid)
        XCTAssertEqual(v.errors.map(\.code), [ValidationCode.modelAutoForbidden], v.dump)
        XCTAssertEqual(v.errors.first?.path, "stages[1].agent.model")
        XCTAssertEqual(v.warnings.map(\.code), [ValidationCode.mcpNotAllowlisted], v.dump)
        XCTAssertEqual(v.warnings.first?.path, "stages[2].agent.mcp[0]")

        let draft = v.draftValidation(projectId: "p-kaban", contentHash: PipelineValidation.contentHash(of: yaml))
        XCTAssertEqual(draft.issues, v.issues)
        XCTAssertEqual(draft.contentHash.count, 64)
        XCTAssertEqual(v.commandResult(contentHash: "h"), .validationIssues(v.issues))
        // Round-trips as the ephemeral event payload.
        let data = try! KabanCoding.makeEncoder().encode(EphemeralEvent.pipelineDraftValidated(draft))
        XCTAssertEqual(try KabanCoding.makeDecoder().decode(EphemeralEvent.self, from: data), .pipelineDraftValidated(draft))
    }

    func testCannotRemoveStageWithActiveTasks() {
        let v = PipelineValidator.validate(yaml: TestPipelines.baseYAML, context: .init(stagesWithActiveTasks: ["dev", "qa"]))
        XCTAssertTrue(v.has(ValidationCode.stageHasActiveTasks, at: "stages"), v.dump)
        XCTAssertEqual(v.errors.count, 1)
        XCTAssertTrue(v.errors[0].message.contains("'qa'"))
    }

    func testGraphRules() {
        let noTerminal = """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: dev }
          - { id: dev, kind: agent, agent: { model: m1 }, on_success: merge }
          - { id: merge, kind: merge, on_success: dev }
          - { id: merge2, kind: merge }
        """
        let v = PipelineValidator.validate(yaml: noTerminal)
        XCTAssertTrue(v.has(ValidationCode.terminalMissing, at: "stages"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.mergeCount, at: "stages[3].kind"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.onSuccessMissing, at: "stages[3].on_success"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.onSuccessCycle, at: "stages[1].on_success"), v.dump)
    }

    func testKindSpecificFields() {
        let yaml = """
        version: 1
        stages:
          - { id: backlog, kind: queue, on_success: dev, gates: [x] }
          - { id: dev, kind: agent, agent: { model: m1, harness: claude-code }, on_success: gate, on_fail: { stage: backlog, limit: 1 } }
          - { id: gate, kind: gate, on_success: human, retry: { max_attempts: 0 } }
          - { id: human, kind: human, on_success: merge, agent: { model: m1 }, returns_to: [{ stage: dev, limit: 1 }] }
          - { id: merge, kind: merge, wip: 2, on_success: done, timeouts: { stall: 2h, wall: 1h } }
          - { id: done, kind: terminal, on_success: dev }
        """
        let v = PipelineValidator.validate(yaml: yaml)
        XCTAssertTrue(v.has(ValidationCode.fieldNotAllowedForKind, at: "stages[0].gates"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.harnessUnsupported, at: "stages[1].agent.harness"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.fieldNotAllowedForKind, at: "stages[1].on_fail"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.missingField, at: "stages[2].gates"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.attemptsOutOfRange, at: "stages[2].retry.max_attempts"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.fieldNotAllowedForKind, at: "stages[3].agent"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.returnsNotAllowed, at: "stages[3].returns_to"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.wipOutOfRange, at: "stages[4].wip"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.durationOutOfRange, at: "stages[4].timeouts.wall") ||
                      v.has(ValidationCode.durationOutOfRange, at: "stages[4].timeouts.stall"), v.dump)
        XCTAssertTrue(v.has(ValidationCode.terminalHasOnSuccess, at: "stages[5].on_success"), v.dump)
    }

    func testTypedConfigValidationAndSummary() {
        let c = TestPipelines.base
        XCTAssertTrue(PipelineValidator.validate(config: c).isValid)
        let summary = c.summary(projectId: "p-kaban", versionHash: "abc")
        XCTAssertEqual(summary.stages.count, 7)
        XCTAssertEqual(summary.maxRunsPerTask, 12)
        XCTAssertEqual(summary.stages[1].model, "composer-2")
        XCTAssertEqual(summary.stages[1].maxAttempts, 3)
        XCTAssertEqual(summary.stages[3].readOnly, true)
        XCTAssertTrue(summary.isValid)
        // Snapshot for `pipeline_version` round-trips through JSON.
        let data = try! JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(PipelineConfig.self, from: data), c)
    }

    func testDurations() {
        XCTAssertEqual(DurationParser.seconds("30s"), 30)
        XCTAssertEqual(DurationParser.seconds("2m"), 120)
        XCTAssertEqual(DurationParser.seconds("1h30m"), 5400)
        XCTAssertEqual(DurationParser.seconds("45"), 45)
        XCTAssertNil(DurationParser.seconds("2x"))
        XCTAssertNil(DurationParser.seconds("m"))
        XCTAssertNil(DurationParser.seconds("1h3"))
        XCTAssertEqual(DurationParser.format(120), "2m")
        XCTAssertEqual(RetryPolicy().pause(afterFailedAttempts: 1), 30)
        XCTAssertEqual(RetryPolicy().pause(afterFailedAttempts: 2), 120)
        XCTAssertEqual(RetryPolicy().pause(afterFailedAttempts: 5), 120)
        XCTAssertEqual(RetryPolicy(maxAttempts: 1, backoffSeconds: []).pause(afterFailedAttempts: 1), 0)
    }

    func testSHA256Vectors() {
        XCTAssertEqual(SHA256Digest.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}
