import XCTest
import KabanProtocol
@testable import KabanKit

final class Team2ValidatorFuzzTests: XCTestCase {
    private func mutatedPipeline(_ index: Int, generator: inout Team2SeededYAML) -> String {
        let base = TestPipelines.baseYAML
        let value = generator.number(100_000)
        switch index % 14 {
        case 0: return base
        case 1: return base.replacingOccurrences(of: "wip: 3", with: "wip: \(value - 50_000)")
        case 2: return base.replacingOccurrences(of: "model: composer-2", with: "model: auto")
        case 3: return base.replacingOccurrences(of: "kind: agent", with: "kind: '\(generator.text(12).replacingOccurrences(of: "'", with: "''"))'")
        case 4: return base + "\nboard: { max_runs_per_task: [\(value)] }"
        case 5: return "version: 1\nversion: \(value)\n" + base
        case 6: return "version: 1\n\tstages: []"
        case 7: return base.replacingOccurrences(of: "on_success: test", with: "on_success: dev")
        case 8: return base + "\nworkspace: {warm_paths: [\(generator.text(30))]}"
        case 9: return base.replacingOccurrences(of: "model: composer-2", with: "model: &anchor m\(value)")
        case 10: return base + "\nworkspace:\n  on_create: |-\n    echo Я🐗\n    echo \(value)"
        case 11: return String(base.prefix(12 + generator.number(base.count - 11)))
        case 12: return base + "\nboard: { max_waiting_human: '\(String(repeating: "9", count: 256 + generator.number(256)))' }"
        default: return base + "\nunknown_\(value): {nested: [null, true, {x: '\(value)'}]}"
        }
    }

    private func assertIssues(_ validation: PipelineValidation, label: String, file: StaticString = #filePath, line: UInt = #line) {
        for issue in validation.issues {
            XCTAssertFalse(issue.code.isEmpty, label, file: file, line: line)
            if issue.code == ValidationCode.yamlSyntax {
                XCTAssertEqual(issue.path, "", label, file: file, line: line)
                XCTAssertGreaterThan(Int(issue.params["line"] ?? "") ?? 0, 0, label, file: file, line: line)
            } else {
                XCTAssertFalse(issue.path.isEmpty, label, file: file, line: line)
            }
        }
        if !validation.isValid { XCTAssertFalse(validation.errors.isEmpty, label, file: file, line: line) }
    }

    func testFiveThousandNearValidPipelinesProduceDeterministicLocatedIssues() {
        var valid = 0
        var invalid = 0
        var codes = Set<String>()
        for seed: UInt64 in [0xB2_2026_1004, 0xFA11_5000] {
            var generator = Team2SeededYAML(seed: seed)
            var replay = Team2SeededYAML(seed: seed)
            for index in 0..<2_500 {
                let text = mutatedPipeline(index, generator: &generator)
                let label = "seed=\(seed) index=\(index) yaml=\(text.debugDescription)"
                XCTAssertEqual(text, mutatedPipeline(index, generator: &replay), label)
                let context = PipelineValidationContext(mcpAllowlist: index.isMultiple(of: 2) ? ["github"] : [],
                                                        stagesWithActiveTasks: index.isMultiple(of: 3) ? ["missing"] : [])
                let first = PipelineValidator.validate(yaml: text, context: context)
                XCTAssertEqual(first, PipelineValidator.validate(yaml: text, context: context), label)
                assertIssues(first, label: label)
                codes.formUnion(first.issues.map(\.code))
                if first.isValid { valid += 1 } else { invalid += 1 }
            }
        }
        XCTAssertGreaterThan(valid, 100)
        XCTAssertGreaterThan(invalid, 1_000)
        XCTAssertTrue(codes.isSuperset(of: [ValidationCode.yamlSyntax, ValidationCode.wipOutOfRange,
                                           ValidationCode.modelAutoForbidden, ValidationCode.typeMismatch,
                                           ValidationCode.onSuccessCycle, ValidationCode.unknownKey,
                                           ValidationCode.stageHasActiveTasks]))
    }

    func testFiveThousandArbitraryRootsRemainDeterministicWithNarrowRootException() {
        var generator = Team2SeededYAML(seed: 0xB2_A11_5000)
        for index in 0..<5_000 {
            let text = generator.input(index)
            let label = "arbitrary-root index=\(index) yaml=\(text.debugDescription)"
            let first = PipelineValidator.validate(yaml: text)
            XCTAssertEqual(first, PipelineValidator.validate(yaml: text), label)
            let root = try? MiniYAML.parse(text)
            if let root, case .mapping = root.value {
                assertIssues(first, label: label)
            } else if root != nil {
                XCTAssertNil(first.config, label)
                XCTAssertEqual(first.issues.count, 1, label)
                XCTAssertEqual(first.issues.first?.code, ValidationCode.typeMismatch, label)
                XCTAssertEqual(first.issues.first?.path, "", label)
                XCTAssertFalse(first.issues.first?.message.isEmpty ?? true, label)
            } else {
                assertIssues(first, label: label)
            }
        }
    }

    func testLongAndDeepUnknownValuesProduceLocatedIssues() {
        let flow = String(repeating: "[", count: 64) + "ok" + String(repeating: "]", count: 64)
        for value in [flow, "'" + String(repeating: "x", count: 65_536) + "'"] {
            let text = TestPipelines.baseYAML + "\nunknown: " + value
            let first = PipelineValidator.validate(yaml: text)
            XCTAssertEqual(first, PipelineValidator.validate(yaml: text))
            XCTAssertTrue(first.isValid, first.dump)
            XCTAssertEqual(first.warnings.first?.path, "unknown")
            assertIssues(first, label: "bounded deep/long root mapping value")
        }
    }

    // #12 resolved: an empty path identifies the document itself, not a missing field path.
    func testNonMappingRootsUseCanonicalDocumentPath() {
        let results = ["x", "[]", ""].map { PipelineValidator.validate(yaml: $0) }
        for validation in results {
            XCTAssertNil(validation.config)
            XCTAssertEqual(validation.issues.count, 1)
            XCTAssertEqual(validation.issues.first?.code, ValidationCode.typeMismatch)
            XCTAssertEqual(validation.issues.first?.path, "")
            XCTAssertFalse(validation.issues.first?.message.isEmpty ?? true)
            XCTAssertFalse(validation.isValid)
        }
    }

    func testSyntaxDiagnosticRootPathIsDocumentedException() {
        let validation = PipelineValidator.validate(yaml: "version: 1\nstages: [")
        XCTAssertEqual(validation.issues.count, 1)
        XCTAssertEqual(validation.issues.first?.code, ValidationCode.yamlSyntax)
        assertIssues(validation, label: "unterminated stages flow list")
    }
}
