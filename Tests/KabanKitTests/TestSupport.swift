import Foundation
import XCTest
import KabanProtocol
@testable import KabanKit

enum Fixtures {
    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

extension PipelineValidation {
    func has(_ code: String, at path: String, _ severity: ValidationIssue.Severity = .error) -> Bool {
        issues.contains { $0.code == code && $0.path == path && $0.severity == severity }
    }
    var dump: String { issues.map { "\($0.severity.rawValue) \($0.path) \($0.code): \($0.message)" }.joined(separator: "\n") }
}

/// The scenario `base` pipeline (Scenarios/README.md) built from YAML, models `composer-2`.
enum TestPipelines {
    static let baseYAML = """
    version: 1
    stages:
      - { id: backlog, kind: queue, on_success: dev }
      - id: dev
        kind: agent
        wip: 3
        agent: { model: composer-2 }
        on_success: test
      - id: test
        kind: agent
        wip: 2
        agent: { model: composer-2 }
        returns_to: [{ stage: dev, limit: 3 }]
        on_success: ai_review
      - id: ai_review
        kind: agent
        wip: 2
        agent: { model: composer-2, permissions: read-only }
        returns_to: [{ stage: dev, limit: 2 }]
        on_success: human_review
      - { id: human_review, kind: human, wip: 5, on_success: merge }
      - { id: merge, kind: merge, on_conflict: { stage: dev, limit: 2 }, on_success: done }
      - { id: done, kind: terminal }
    """

    static var base: PipelineConfig {
        let v = PipelineValidator.validate(yaml: baseYAML)
        precondition(v.isValid, v.issues.map(\.message).joined(separator: "\n"))
        return v.config!
    }

    /// `base` plus a gate stage with `on_fail`, small limits to make property tests hit every limit quickly.
    static let smallLimitsYAML = """
    version: 1
    board: { max_waiting_human: 3, bounce_limit_total: 6, max_runs_per_task: 6 }
    git: { preset: strict }
    stages:
      - { id: backlog, kind: queue, on_success: dev }
      - id: dev
        kind: agent
        agent: { model: composer-2 }
        retry: { max_attempts: 3, backoff: [30s, 2m] }
        on_success: lint
      - id: lint
        kind: gate
        gates: [make lint]
        on_fail: { stage: dev, limit: 2 }
        on_success: test
      - id: test
        kind: agent
        agent: { model: gpt-5 }
        retry: { max_attempts: 2, backoff: [10s] }
        returns_to: [{ stage: dev, limit: 2 }]
        on_success: review
      - id: review
        kind: agent
        agent: { model: gpt-5, permissions: read-only }
        returns_to: [{ stage: dev, limit: 1 }, { stage: test, limit: 1 }]
        on_success: human
      - { id: human, kind: human, on_success: merge }
      - { id: merge, kind: merge, gates: [make test], on_conflict: { limit: 2 }, on_success: done }
      - { id: done, kind: terminal }
    """

    static var smallLimits: PipelineConfig {
        let v = PipelineValidator.validate(yaml: smallLimitsYAML)
        precondition(v.isValid, v.issues.map(\.message).joined(separator: "\n"))
        return v.config!
    }
}
