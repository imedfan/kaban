import Foundation
import XCTest
import KabanProtocol
@testable import KabanKit

final class Team2TakeoverIdentitySizeReasonTests: XCTestCase {
    func testCRLFAndWhitespaceLineBreaksAreInvalidBeforeTrimming() throws {
        let cases: [(GitIdentity, [String: String])] = [
            (.init(name: "A\r\nB", email: "a@example.com"), ["invalid": "name", "email": "a@example.com"]),
            (.init(name: "A", email: "a\r\nb"), ["invalid": "email", "name": "A"]),
            (.init(name: " \r\n\t", email: " \r\n "), ["invalid": "name,email"]),
            (.init(name: " \n ", email: "a@example.com"), ["invalid": "name", "email": "a@example.com"]),
            (.init(name: "A\0B", email: "a@example.com"), ["invalid": "name", "email": "a@example.com"]),
        ]
        for (input, params) in cases {
            XCTAssertThrowsError(try input.validated()) { XCTAssertEqual(($0 as? GitIdentityRequired)?.params, params) }
            XCTAssertThrowsError(try DaemonGit.arguments(["commit"], identity: input)) {
                guard let error = $0 as? DaemonGit.BuildError, case .invalidIdentity(let required) = error else {
                    return XCTFail("Expected invalidIdentity, got \($0)")
                }
                XCTAssertEqual(required.params, params)
            }
        }
        XCTAssertEqual(try GitIdentity(name: " Яé🐗\t", email: " a@example.com ").validated(),
                       GitIdentity(name: "Яé🐗", email: "a@example.com"))
    }
    func testRealRepositoryCRLFIdentityIsRejected() throws {
        let s = try DaemonGitTests.Sandbox.make()
        defer { try? FileManager.default.removeItem(at: s.root) }
        var env = s.baseEnvironment
        env["GIT_CONFIG_SYSTEM"] = s.root.appendingPathComponent("system").path
        env["GIT_CONFIG_GLOBAL"] = s.root.appendingPathComponent("global").path
        try s.write("", to: "system"); try s.write("", to: "global")
        try s.git(["init", "-q", "-b", "main", "repo"], env: env)
        let repo = s.root.appendingPathComponent("repo").path
        try s.git(["-C", repo, "config", "user.name", "A\r\nB"], env: env)
        try s.git(["-C", repo, "config", "user.email", "found@example.com"], env: env)
        XCTAssertThrowsError(try GitIdentity.resolveForProject(explicit: nil, repositoryPath: repo, environment: env)) {
            XCTAssertEqual(($0 as? GitIdentityRequired)?.params, ["invalid": "name", "email": "found@example.com"])
        }
    }
    func testSizeByteThresholdSaturatesAtInt64CapacityWithoutProductMaximum() {
        let capacityMB = Double(Int64.max) / (1024 * 1024)
        let thresholds = [capacityMB.nextDown, capacityMB, capacityMB.nextUp, 1e20, Double.greatestFiniteMagnitude]
        var previous: Int64 = 0
        for mb in thresholds {
            let policy = SuspiciousFilesPolicy(patterns: [], maxFileMB: mb, allow: [])
            XCTAssertGreaterThanOrEqual(policy.maxFileBytes, previous)
            previous = policy.maxFileBytes
            let result = SuspiciousFilesScanner.scan([ChangedFile(path: "ordinary", sizeBytes: Int64.max, blob: "synthetic")], policy: policy)
            XCTAssertEqual(result.count, policy.maxFileBytes == Int64.max ? 0 : 1)
        }
        XCTAssertLessThan(SuspiciousFilesPolicy(maxFileMB: capacityMB.nextDown).maxFileBytes, Int64.max)
        XCTAssertEqual(SuspiciousFilesPolicy(maxFileMB: capacityMB).maxFileBytes, Int64.max)
        XCTAssertEqual(SuspiciousFilesPolicy(maxFileMB: 5).maxFileBytes, 5 * 1024 * 1024)
    }
    func testHugeFiniteThresholdSurvivesYAMLValidationAndScanner() throws {
        let yaml = PipelineTemplate.defaultYAML.replacingOccurrences(of: "model:", with: "model: test")
            .replacingOccurrences(of: "max_file_mb: 5", with: "max_file_mb: 1e20")
        let validation = PipelineValidator.validate(yaml: yaml)
        XCTAssertTrue(validation.isValid, "\(validation.issues)")
        let policy = try XCTUnwrap(validation.config).suspiciousFiles
        XCTAssertTrue(SuspiciousFilesScanner.scan([ChangedFile(path: "ordinary", sizeBytes: 1, blob: "synthetic")], policy: policy).isEmpty)
    }
    func testInvalidTypedThresholdsHaveDiagnosticsAndUncheckedConversionDoesNotTrap() throws {
        let base = try XCTUnwrap(PipelineValidator.validate(yaml: PipelineTemplate.defaultYAML.replacingOccurrences(of: "model:", with: "model: test")).config)
        for threshold in [Double.nan, Double.infinity, -Double.infinity, -1, 0] {
            var config = base
            config.suspiciousFiles.maxFileMB = threshold
            let validation = PipelineValidator.validate(config: config)
            XCTAssertFalse(validation.isValid)
            XCTAssertTrue(validation.errors.contains { $0.path == "suspicious_files.max_file_mb" && $0.code == ValidationCode.limitOutOfRange })
            XCTAssertEqual(config.suspiciousFiles.maxFileBytes, 0)
        }
    }
    func testReadonlyReasonChargesAttemptKeepsBackoffAndSecondStrikeEscalates() {
        let stage = StageConfig(id: "review", kind: .agent, agent: .init(model: "test", permissions: .readOnly), onSuccess: "done")
        let pipeline = PipelineConfig(stages: [stage, StageConfig(id: "done", kind: .terminal)])
        var state = TaskMachineState(taskId: "t", stageId: "review")
        func apply(_ event: TaskEvent) -> TransitionResult {
            let result = TaskMachine.transition(state, event, pipeline: pipeline)
            state = result.state
            return result
        }
        for run in ["r1", "r2"] {
            _ = apply(.start(runId: RunID(rawValue: run)))
            _ = apply(.completeStage(runId: RunID(rawValue: run), summary: "synthetic"))
            _ = apply(.gatesPassed)
            let result = apply(.resultChecked(.readOnlyChanges))
            XCTAssertTrue(result.effects.contains(.saveWipAndRollback(RunID(rawValue: run))))
            if run == "r1" {
                XCTAssertEqual(state.state, .retryWait(.readonlyViolation))
                XCTAssertEqual(state.attemptsUsed, 1)
                XCTAssertTrue(state.pendingPrompt.contains(.readOnlyViolation))
                XCTAssertTrue(result.effects.contains(.scheduleRetry(afterSeconds: 30, reason: .readonlyViolation)))
            } else {
                XCTAssertEqual(state.state, .waitingHuman(.invalidResult))
            }
        }
    }
}
