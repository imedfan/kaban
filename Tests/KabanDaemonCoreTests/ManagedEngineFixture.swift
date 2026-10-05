import Foundation
import XCTest
import KabanKit
import KabanProtocol
import KabanDaemonCore

enum ManagedEngineFixture {
    static func pipeline() throws -> PipelineConfig {
        let result = PipelineValidator.validate(yaml: """
        version: 1
        board: {max_waiting_human: 2, bounce_limit_total: 5, max_runs_per_task: 12}
        stages:
          - id: queue
            name: Queue
            kind: queue
            on_success: agent
          - id: agent
            name: Agent
            kind: agent
            wip: 2
            agent: {harness: cursor-cli, model: fake, skill: test.md, permissions: write, mcp: [kaban]}
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review
          - id: review
            name: Review
            kind: human
            wip: 1
            on_success: done
          - id: done
            name: Done
            kind: terminal
        """)
        XCTAssertTrue(result.errors.allSatisfy { $0.code == "merge_count" }, "\(result.errors)")
        return try XCTUnwrap(result.config)
    }

    static func drain(_ store: KabanStore, at: Date) throws {
        for _ in 0..<8 {
            let effects = try store.pendingEffectItems()
            if effects.isEmpty { return }
            for effect in effects {
                let result = try FakeDriver.result(for: effect, agent: .completed(summary: "Explicit fixture completion"))
                _ = try store.deliverFake(effectId: effect.id, result: result, at: at)
            }
        }
        XCTFail("Fake drain did not converge")
    }
}
