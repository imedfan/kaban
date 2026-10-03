import XCTest
import KabanProtocol
@testable import KabanKit

/// `waiting_human: suspicious_files` rules (architecture v0.11.1 §5, §8.2).
final class SuspiciousFilesMachineTests: XCTestCase {
    let base = TestPipelines.base
    let envLocal = SuspiciousFile(path: ".env.local", rule: .pattern, pattern: ".env*", sizeBytes: 212, blob: "a1b2c3")
    let dump = SuspiciousFile(path: "assets/dump.bin", rule: .size, sizeBytes: 7_340_032, blob: "d4e5f6")

    func blocked(stage: StageID = "dev") -> Harness {
        var h = Harness(base, stage: stage)
        if stage == "merge" {
            h.ok(.start(runId: "m"))
        } else {
            h.ok(.start(runId: "r-1"))
            h.ok(.completeStage(runId: "r-1", summary: "s"))
        }
        h.ok(.gatesPassed)
        let e = h.ok(.resultChecked(.suspiciousFiles([envLocal, dump])))
        XCTAssertEqual(h.s.state, .waitingHuman(.suspiciousFiles))
        XCTAssertTrue(e.contains(.reportSuspiciousFiles([envLocal, dump], runId: stage == "merge" ? nil : "r-1")))
        XCTAssertEqual(h.s.suspiciousFiles, [envLocal, dump])
        return h
    }

    func testFoundDoesNotBurnAttemptButRunCounts_SUSP01() {
        let h = blocked()
        XCTAssertEqual(h.s.attemptsUsed, 0)
        XCTAssertEqual(h.attempt, 1)
        XCTAssertEqual(h.s.runsSinceHuman, 1)
        XCTAssertTrue(h.s.state.countsTowardMaxWaitingHuman)
    }

    func testAcceptExactSetRechecksAndContinuesWithoutRun_SUSP01() {
        var h = blocked()
        let e = h.ok(.human(.acceptSuspiciousFiles([FileBlobRef(path: "assets/dump.bin", blob: "d4e5f6"),
                                                    FileBlobRef(path: ".env.local", blob: "a1b2c3")])))
        XCTAssertEqual(e.accepted, [envLocal, dump])
        XCTAssertEqual(e.last, .runResultCheck(stageId: "dev"))
        XCTAssertEqual(h.s.state, .gating)
        XCTAssertEqual(h.s.suspiciousFiles, [])
        XCTAssertEqual(h.s.runsSinceHuman, 0)
        let next = h.ok(.resultChecked(.clean))
        XCTAssertEqual(h.s.stageId, "test")
        XCTAssertEqual(h.s.state, .queued(nil))
        XCTAssertTrue(next.startedRuns.isEmpty)
        XCTAssertTrue(next.contains(.commitStage(.safety)))
    }

    func testAcceptStaleSetIsRejected_SUSP03() {
        var h = blocked()
        let before = h.s
        for shown in [[FileBlobRef(path: ".env.local", blob: "a1b2c3")],                                     // subset
                      [FileBlobRef(path: ".env.local", blob: "ffff01"), FileBlobRef(path: "assets/dump.bin", blob: "d4e5f6")], // other blob
                      [FileBlobRef(path: ".env.local", blob: "a1b2c3"), FileBlobRef(path: "assets/dump.bin", blob: "d4e5f6"),
                       FileBlobRef(path: "x.pem", blob: "1")]] {                                             // superset
            let r = h.send(.human(.acceptSuspiciousFiles(shown)))
            guard case .rejected(let err) = r.outcome else { return XCTFail("expected rejection for \(shown)") }
            XCTAssertEqual(err.code, CommandError.staleSuspiciousFilesCode)
            XCTAssertEqual(r.effects, [])
            XCTAssertEqual(h.s, before)
        }
        // Not waiting on files at all → also stale (nothing to accept).
        var other = Harness(base, stage: "dev", state: .waitingHuman(.question))
        guard case .rejected(let err) = other.send(.human(.acceptSuspiciousFiles([]))).outcome else { return XCTFail() }
        XCTAssertEqual(err.code, CommandError.staleSuspiciousFilesCode)
    }

    func testRecheckCanFindNewFilesAgain() {
        var h = blocked()
        h.ok(.human(.acceptSuspiciousFiles([envLocal, dump].map { FileBlobRef(path: $0.path, blob: $0.blob) })))
        let newer = SuspiciousFile(path: ".env.local", rule: .pattern, pattern: ".env*", sizeBytes: 230, blob: "ffff01")
        h.ok(.resultChecked(.suspiciousFiles([newer])))
        XCTAssertEqual(h.s.state, .waitingHuman(.suspiciousFiles))
        XCTAssertEqual(h.s.suspiciousFiles, [newer])
    }

    func testAnswerDoesNotAcceptAndStartsNewRun_SUSP04() {
        var h = blocked()
        let e = h.ok(.human(.answer(text: "remove .env.local from the branch", requestId: nil)))
        XCTAssertNil(e.accepted, "answerHuman must not accept the set")
        XCTAssertEqual(h.s.state, .queued(nil))
        XCTAssertEqual(h.s.stageId, "dev")
        XCTAssertEqual(h.s.suspiciousFiles, [])
        let r = h.ok(.start(runId: "r-2")).startedRuns
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].prompt, [.humanAnswer("remove .env.local from the branch")])
        XCTAssertEqual(r[0].attempt, 1)
        h.ok(.completeStage(runId: "r-2", summary: "s"))
        h.ok(.gatesPassed)
        h.ok(.resultChecked(.suspiciousFiles([envLocal])))
        XCTAssertEqual(h.s.state, .waitingHuman(.suspiciousFiles))
    }

    func testOtherHumanExitsAcceptTheSet_SUSP05() {
        let actions: [(HumanAction, TaskState, StageID)] = [
            (.retryStage(grantAttempts: nil), .queued(nil), "dev"),
            (.move(stage: "backlog"), .queued(nil), "backlog"),
            (.requestChanges(comments: "fix", target: "dev"), .queued(nil), "dev"),
            (.reject(target: .stage(stageId: "dev"), keepBranch: false), .queued(nil), "dev"),
            (.reject(target: .cancel, keepBranch: false), .cancelled, "dev"),
            (.cancel(keepBranch: true), .cancelled, "dev"),
        ]
        for (action, state, stage) in actions {
            var h = blocked()
            let e = h.ok(.human(action))
            XCTAssertEqual(e.accepted, [envLocal, dump], "\(action)")
            XCTAssertEqual(h.s.state, state, "\(action)")
            XCTAssertEqual(h.s.stageId, stage, "\(action)")
            XCTAssertEqual(h.s.suspiciousFiles, [])
            XCTAssertTrue(e.startedRuns.isEmpty)
        }
    }

    func testMergeStageAcceptLeadsToFastForward() {
        var h = blocked(stage: "merge")
        h.ok(.human(.acceptSuspiciousFiles([envLocal, dump].map { FileBlobRef(path: $0.path, blob: $0.blob) })))
        XCTAssertEqual(h.ok(.resultChecked(.clean)).last, .fastForwardMerge)
        h.ok(.merged)
        XCTAssertEqual(h.s.state, .done)
        // answerHuman has no agent to talk to in the merge stage.
        var m = blocked(stage: "merge")
        if case .rejected = m.send(.human(.answer(text: "x", requestId: nil))).outcome {} else { XCTFail() }
    }
}
