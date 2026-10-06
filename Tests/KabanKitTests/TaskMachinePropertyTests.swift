import XCTest
import KabanProtocol
@testable import KabanKit

/// Tiny deterministic PRNG (SplitMix64) — no external dependencies, reproducible by seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
}

/// Random event generator biased toward events that are legal in the current state, plus noise (stale runs, illegal calls).
struct EventGenerator {
    var rng: SplitMix64
    let pipeline: PipelineConfig
    var runCounter = 0
    var humanPercent: Int

    mutating func runId(_ s: TaskMachineState) -> RunID {
        if rng.chance(85), let r = s.currentRunId ?? s.lastRunId { return r }
        return RunID(rawValue: "stale-\(rng.int(3))")
    }

    mutating func files() -> [SuspiciousFile] {
        (0..<rng.int(3)).map { i in SuspiciousFile(path: ".env.\(i)", rule: .pattern, pattern: ".env*", sizeBytes: 10, blob: "b\(rng.int(3))") }
    }

    mutating func next(_ s: TaskMachineState) -> TaskEvent {
        let stages = pipeline.stages.map(\.id) + ["ghost"]
        // Bias toward events that make progress in the current state; keep a share of pure noise.
        let waiting: Bool = { switch s.state { case .waitingHuman, .paused: return true; default: return false } }()
        if !rng.chance(25) && !(waiting && rng.chance(50)) {
            switch s.state {
            case .queued, .retryWait:
                if rng.chance(85) { runCounter += 1; return .start(runId: RunID(rawValue: "r-\(runCounter)")) }
            case .running:
                switch rng.int(10) {
                case 0, 1, 2: return .completeStage(runId: runId(s), summary: "s")
                case 3, 4:
                    if let t = pipeline.stage(s.stageId)?.returnsTo.first?.stage { return .returnToStage(runId: runId(s), target: t, issues: ["i"]) }
                case 5, 6, 7: return .runEnded(runId: runId(s), rng.pick([.crash, .stallTimeout, .noFinalCall, .crash]))
                default: break
                }
            case .gating:
                if s.gatingPhase == .rebase, rng.chance(50) { return .mergeConflict(files: ["f"]) }
                if pipeline.stage(s.stageId)?.isReadOnly == true, s.gatingPhase == .resultCheck, rng.chance(50) {
                    return .resultChecked(.readOnlyChanges)
                }
                switch rng.int(8) {
                case 0, 1: return .gatesPassed
                case 2: return .gatesFailed(output: "red")
                case 3, 4: return .resultChecked(.clean)
                case 5: return .mergeConflict(files: ["f"])
                case 6: return .merged
                default: break
                }
            case .waitingHuman(.review):
                return .human(rng.chance(80) ? .approve : .requestChanges(comments: "c", target: nil))
            default: break
            }
        }
        if rng.chance(waiting ? 60 : humanPercent) {
            let action: HumanAction
            switch rng.int(10) {
            case 0: action = .answer(text: "a", requestId: nil)
            case 1: action = .approve
            case 2: action = .requestChanges(comments: "c", target: rng.chance(50) ? nil : rng.pick(stages))
            case 3: action = .reject(target: rng.chance(30) ? .cancel : .stage(stageId: rng.pick(stages)), keepBranch: rng.chance(50))
            case 4: action = .pause
            case 5: action = .resume
            case 6: action = .move(stage: rng.pick(stages))
            case 7: action = .retryStage(grantAttempts: rng.chance(50) ? nil : rng.int(3))
            case 8: action = rng.chance(10) ? .cancel(keepBranch: rng.chance(50)) : .resume
            default:
                let exact = s.suspiciousFiles.map { FileBlobRef(path: $0.path, blob: $0.blob) }
                action = .acceptSuspiciousFiles(rng.chance(70) ? exact : files().map { FileBlobRef(path: $0.path, blob: $0.blob) })
            }
            return .human(action)
        }
        switch rng.int(20) {
        case 0, 1, 2:
            runCounter += 1
            return .start(runId: RunID(rawValue: "r-\(runCounter)"))
        case 3: return .startBlocked(rng.pick([.wipFull, .quota(.cm), .quota(.om), .modelFlag]))
        case 4, 5: return .completeStage(runId: runId(s), summary: "s")
        case 6:
            let targets = (pipeline.stage(s.stageId)?.returnsTo.map(\.stage) ?? []) + ["backlog"]
            return .returnToStage(runId: runId(s), target: rng.pick(targets), issues: ["i"])
        case 7: return .requestHuman(runId: runId(s), question: "q")
        case 8, 9:
            let failure: RunFailure = rng.pick([.crash, .stallTimeout, .wallTimeout, .noFinalCall, .rateLimit, .runnerAuth,
                                                 .silentExit, .usageExhausted(.cm), .usageExhausted(nil), .modelUnavailable])
            return .runEnded(runId: runId(s), failure)
        case 10: return rng.chance(50) ? .modelMismatch(runId: runId(s), requested: "a", actual: "b", fallback: nil) : .gitDenialLimit(runId: runId(s))
        case 11: return rng.chance(50) ? .daemonRestarted : .probeFinished(rng.pick([.clean, .rateLimit, .usageExhausted(.om), .modelUnavailable]))
        case 12, 13: return .gatesPassed
        case 14: return .gatesFailed(output: "red")
        case 15, 16:
            switch rng.int(6) {
            case 0: return .resultChecked(.suspiciousFiles(files()))
            case 1: return .resultChecked(.incident(.refsMoved))
            case 2: return .resultChecked(.readOnlyChanges)
            default: return .resultChecked(.clean)
            }
        case 17: return .mergeConflict(files: ["f"])
        case 18: return rng.pick([.mainDirty, .mainCleaned, .mainMoved])
        default: return .merged
        }
    }
}

final class TaskMachinePropertyTests: XCTestCase {
    struct Violation: Error, CustomStringConvertible { let description: String }

    static func isNonCharging(_ e: TaskEvent) -> Bool {
        switch e {
        case .runEnded(_, let f): return !f.charges
        case .modelMismatch, .daemonRestarted, .startBlocked, .resultChecked(.suspiciousFiles), .resultChecked(.incident): return true
        case .probeFinished(let p): return p != .clean
        default: return false
        }
    }

    /// Checks all invariants for one step. Returns a description of the first violation.
    static func check(_ prev: TaskMachineState, _ e: TaskEvent, _ r: TransitionResult, _ p: PipelineConfig) -> String? {
        let s = r.state
        // Determinism
        if TaskMachine.transition(prev, e, pipeline: p) != r { return "non-deterministic" }
        // Rejected / ignored change nothing
        if r.outcome != .applied, s != prev || !r.effects.isEmpty { return "non-applied outcome changed state or produced effects" }
        // Final states are absorbing
        if prev.state == .done || prev.state == .cancelled, s != prev { return "left a final state" }
        // Human-only exits
        let isHuman: Bool = { if case .human = e { return true }; return false }()
        let moved = s.state != prev.state || s.stageId != prev.stageId
        if !isHuman, moved {
            switch prev.state {
            case .waitingHuman, .paused: return "left \(prev.state) without a human action"
            case .blocked: if e != .mainCleaned { return "left blocked without main cleanup or human" }
            default: break
            }
        }
        guard let stage = p.stage(s.stageId) else { return "stage \(s.stageId) not in pipeline" }
        // Counters
        if s.attemptsUsed > s.attemptLimit(stage) { return "attempts \(s.attemptsUsed) > limit \(s.attemptLimit(stage))" }
        if s.runsSinceHuman < 0 || s.runsSinceHuman > p.board.maxRunsPerTask { return "runsSinceHuman \(s.runsSinceHuman) out of 0…\(p.board.maxRunsPerTask)" }
        if Self.isNonCharging(e), s.stageId == prev.stageId {
            if s.attemptsUsed > prev.attemptsUsed { return "non-charging event incremented attempts" }
            if s.runsSinceHuman > prev.runsSinceHuman { return "non-charging event incremented runs" }
        }
        if case .runEnded(_, let f) = e, !f.charges, r.outcome == .applied, s.runsSinceHuman != max(0, prev.runsSinceHuman - 1) {
            return "non-charging run was not refunded"
        }
        if isHuman, r.outcome == .applied, s.runsSinceHuman != 0 { return "human action did not reset runsSinceHuman" }
        if !isHuman, r.effects.accepted != nil { return "suspicious files accepted without a human" }
        // Bounces
        if s.totalBounces > p.board.bounceLimitTotal { return "totalBounces over limit" }
        for (key, n) in s.bounces {
            let limit: Int? = key == TaskMachineState.conflictBounceKey ? p.mergeStage?.conflictReturn(in: p)?.limit
                : p.stages.lazy.flatMap { st in (st.returnsTo + [st.failReturn(in: p)].compactMap { $0 }).map { (TaskMachineState.bounceKey(from: st.id, to: $0.stage), $0.limit) } }
                    .first { $0.0 == key }?.1
            guard let limit, n <= limit else { return "bounce \(key)=\(n) over limit" }
        }
        // Status consistency
        if (s.state == .running) != (s.currentRunId != nil) { return "running ⇔ currentRunId broken" }
        if s.state.status.occupiesWIP && ![.agent, .gate, .merge].contains(stage.kind) { return "\(s.state) holds WIP in a \(stage.kind) stage" }
        if s.state == .running && stage.kind != .agent { return "running outside an agent stage" }
        if s.state == .waitingHuman(.review) && stage.kind != .human { return "review outside a human stage" }
        if s.state == .done && stage.kind != .terminal { return "done outside terminal stage" }
        if !s.suspiciousFiles.isEmpty && s.state != .waitingHuman(.suspiciousFiles) { return "suspicious set outside its waiting state" }
        if s.state == .waitingHuman(.suspiciousFiles) && s.suspiciousFiles.isEmpty { return "empty suspicious set while waiting on it" }
        // Effects
        for run in r.effects.startedRuns {
            if s.state != .running || s.currentRunId != run.runId { return "run started but task not running it" }
            if prev.runsSinceHuman >= p.board.maxRunsPerTask { return "run started over max_runs_per_task" }
        }
        if r.outcome == .applied, moved {
            guard case .recordTransition(let t)? = r.effects.first, t.from == prev.state, t.to == s.state,
                  t.fromStage == prev.stageId, t.toStage == s.stageId else { return "missing/wrong recordTransition" }
        }
        return nil
    }

    func runSeeds(_ p: PipelineConfig, seeds: Range<UInt64>, steps: Int, humanPercent: Int) -> [String: Int] {
        var reached: [String: Int] = [:]
        for seed in seeds {
            var gen = EventGenerator(rng: SplitMix64(seed: seed), pipeline: p, humanPercent: humanPercent)
            var s = TaskMachineState.new(taskId: "t", pipeline: p)!
            var trace: [String] = []
            for step in 0..<steps {
                let e = gen.next(s)
                let r = TaskMachine.transition(s, e, pipeline: p)
                trace.append("\(step): \(e) -> \(r.state.stageId)/\(r.state.state) \(r.outcome)")
                if let v = Self.check(s, e, r, p) {
                    XCTFail("seed \(seed) step \(step): \(v)\n" + trace.suffix(12).joined(separator: "\n"))
                    return reached
                }
                if r.state.state != s.state { reached[r.state.state.reasonRawValue ?? r.state.state.status.rawValue, default: 0] += 1 }
                s = r.state
            }
        }
        return reached
    }

    func testInvariantsOnSmallLimitsPipeline() {
        let reached = runSeeds(TestPipelines.smallLimits, seeds: 1..<401, steps: 300, humanPercent: 8)
        // The generator must actually exercise the interesting limits, otherwise the test proves little.
        for reason in ["retries_exhausted", "run_limit", "bounce_limit", "conflict_limit", "suspicious_files", "model_substituted",
                       "invalid_result", "git_denials", "incident", "question", "review", "done", "cancelled", "quota_om", "silent_exit"] {
            XCTAssertGreaterThan(reached[reason] ?? 0, 0, "never reached \(reason): \(reached)")
        }
    }

    func testInvariantsOnBasePipeline() {
        _ = runSeeds(TestPipelines.base, seeds: 1000..<1200, steps: 400, humanPercent: 4)
    }

    func testReplayIsDeterministic() {
        let p = TestPipelines.smallLimits
        func replay(seed: UInt64) -> [TransitionResult] {
            var gen = EventGenerator(rng: SplitMix64(seed: seed), pipeline: p, humanPercent: 10)
            var s = TaskMachineState.new(taskId: "t", pipeline: p)!
            return (0..<200).map { _ in let r = TaskMachine.transition(s, gen.next(s), pipeline: p); s = r.state; return r }
        }
        XCTAssertEqual(replay(seed: 42), replay(seed: 42))
        XCTAssertNotEqual(replay(seed: 42), replay(seed: 43))
    }
}
