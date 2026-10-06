import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class EffectExecutionTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let yaml = """
    version: 1
    board: {max_waiting_human: 2, max_runs_per_task: 20}
    stages:
      - {id: backlog, kind: queue, on_success: dev}
      - id: dev
        kind: agent
        wip: 4
        agent: {model: explicit, skill: .kaban/dev.md}
        retry: {max_attempts: 3, backoff: [30s]}
        on_success: inspect
      - id: inspect
        kind: agent
        wip: 4
        agent: {model: composer-fast, skill: .kaban/dev.md}
        on_success: check
      - {id: check, kind: gate, wip: 2, gates: ["echo check"], on_success: review}
      - {id: review, kind: human, wip: 2, on_success: merge}
      - {id: merge, kind: merge, gates: ["echo merge"], on_success: done}
      - {id: done, kind: terminal}

    """

    struct Fixture { let root: URL; let path: String; var store: KabanStore }

    func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-effect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        try yaml.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try "skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["config", "user.name", "Effect Test"])
        try git(repo, ["config", "user.email", "effect@example.test"])
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "Pipeline"])
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result, .ok)
        _ = try store.setSettings(.init(maxConcurrentRuns: 2, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        return Fixture(root: root, path: path, store: store)
    }

    func git(_ repo: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.environment = DaemonGit.processEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(args)")
    }

    @discardableResult
    func create(_ f: Fixture, _ id: TaskID, commandId: UUID = UUID()) throws -> TaskID {
        let reply = try f.store.execute(.init(commandId: commandId, command: .createTask(projectId: try projectId(f), title: id.rawValue, body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), now: { self.at }, makeTaskID: { id })
        XCTAssertEqual(reply.result, .taskCreated(id), "\(reply)")
        return id
    }

    func projectId(_ f: Fixture) throws -> ProjectID {
        try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
    }

    func launch(_ f: Fixture, _ id: TaskID) throws -> PendingEffect {
        _ = try create(f, id)
        let moved = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-admit"), at: at)
        XCTAssertEqual(moved.transitions.last?.task.machine.stageId, "dev")
        let started = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-run"), at: at)
        XCTAssertEqual(started.transitions.last?.task.machine.state, .running)
        return try XCTUnwrap(f.store.pendingEffectItems().first { effect in
            if case .startAgentRun = effect.effect { return effect.taskId == id }
            return false
        })
    }

    func task(_ store: KabanStore, _ id: TaskID) throws -> DurableTask {
        try XCTUnwrap(store.snapshot().tasks.first { $0.card.id == id })
    }

    struct EffectRow {
        var status: String
        var payload: Data
        var result: Data?
        var fact: Data?
        var receipt: Data?
        var diagnostic: String?
        var fencing: Int
        var leaseId: String?
    }

    func row(_ store: KabanStore, _ id: String) throws -> EffectRow {
        try store.database.read { db in
            let record = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT payload, status, result, external_fact, receipt, diagnostic, fencing, lease_id FROM effect WHERE id = ?", arguments: [id]))
            return EffectRow(status: record["status"], payload: record["payload"], result: record["result"], fact: record["external_fact"], receipt: record["receipt"], diagnostic: record["diagnostic"], fencing: record["fencing"], leaseId: record["lease_id"])
        }
    }

    func finished(_ effectId: String, _ outcome: RealEffectOutcome) -> ExternalEffectFact {
        ExternalEffectFact(actionId: effectId + "/observed", phase: .finished, outcome: outcome)
    }

    func testTwoWorkersClaimOneEffectAndSeeItOnlyAfterCommit() throws {
        let f = try fixture()
        let effect = try launch(f, "task")
        let original = try row(f.store, effect.id).payload
        let other = try KabanStore(path: f.path)
        let box = LeaseBox()
        let start = DispatchGroup()
        let finish = DispatchGroup()
        start.enter(); start.enter(); finish.enter(); finish.enter()
        let moment = at
        for (index, store) in [f.store, other].enumerated() {
            DispatchQueue.global().async {
                start.leave()
                start.wait()
                do { box.add(try store.claimEffect(owner: "worker-\(index)", leaseFor: 30, at: moment)) }
                catch { box.fail(error) }
                finish.leave()
            }
        }
        XCTAssertEqual(finish.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(box.errors.isEmpty, "\(box.errors)")
        let claimed = box.values.compactMap { $0 }
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(box.values.filter { $0 == nil }.count, 1)
        let lease = try XCTUnwrap(claimed.first)
        XCTAssertEqual(lease.fencing, 1)
        XCTAssertEqual(lease.payload, effect)
        let visible = try row(other, effect.id)
        XCTAssertEqual(visible.status, "claimed")
        XCTAssertNil(visible.receipt)
        XCTAssertNil(visible.fact)
        XCTAssertEqual(visible.payload, original)
        XCTAssertNil(try f.store.claimEffect(owner: "late", leaseFor: 30, at: at))
    }

    func testCrashBeforeExternalActionReclaimsWithoutExactlyOnceAndCrashAfterReceiptsOnce() throws {
        let f = try fixture()
        let effect = try launch(f, "task")
        let original = try row(f.store, effect.id).payload
        let lease = try XCTUnwrap(f.store.claimEffect(owner: "worker", leaseFor: 60, at: at))
        let reopened = try KabanStore(path: f.path)
        XCTAssertTrue(try reopened.recoverEffectExecution(at: at, reclaimUnexpired: true).isEmpty)
        let recovered = try row(reopened, effect.id)
        XCTAssertEqual(recovered.status, "pending")
        XCTAssertEqual(recovered.diagnostic, EffectExecutionDiagnostic.reclaim)
        XCTAssertEqual(recovered.payload, original)
        XCTAssertNil(recovered.receipt)
        XCTAssertEqual(try task(reopened, "task").machine.state, .running)
        let again = try XCTUnwrap(reopened.claimEffect(owner: "worker", leaseFor: 60, at: at))
        XCTAssertEqual(again.fencing, 2)
        XCTAssertNotEqual(again.leaseId, lease.leaseId)

        let started = ExternalEffectFact(actionId: effect.id + "/observed", phase: .started)
        try reopened.recordExternalFact(effectId: effect.id, leaseId: again.leaseId, fact: started)
        let held = try KabanStore(path: f.path)
        XCTAssertTrue(try held.recoverEffectExecution(at: at, reclaimUnexpired: true).isEmpty)
        let observed = try row(held, effect.id)
        XCTAssertEqual(observed.status, "claimed")
        XCTAssertEqual(observed.diagnostic, EffectExecutionDiagnostic.observedUnfinished)
        XCTAssertEqual(observed.payload, original)
        XCTAssertNil(observed.receipt)
        XCTAssertNil(try held.claimEffect(owner: "other", leaseFor: 30, at: at))
        XCTAssertEqual(try task(held, "task").machine.state, .running)

        let fact = finished(effect.id, .completed(summary: "Done"))
        try held.recordExternalFact(effectId: effect.id, leaseId: again.leaseId, fact: fact)
        let crashed = try KabanStore(path: f.path)
        let first = try crashed.recoverEffectExecution(at: at.addingTimeInterval(5), reclaimUnexpired: true)
        XCTAssertEqual(first.count, 1)
        let quiet = try KabanStore(path: f.path)
        XCTAssertTrue(try quiet.recoverEffectExecution(at: at.addingTimeInterval(9), reclaimUnexpired: true).isEmpty)
        XCTAssertEqual(try row(quiet, effect.id).receipt, try KabanStore.encode(first[0]))
        XCTAssertEqual(try task(quiet, "task").machine.state, .gating)
        XCTAssertEqual(try row(quiet, effect.id).payload, original)
        XCTAssertNil(try quiet.claimEffect(id: effect.id, owner: "other", leaseFor: 30, at: at))
        XCTAssertThrowsError(try quiet.deliverFake(effectId: effect.id, result: .completed(summary: "Done"), at: at)) { XCTAssertEqual($0 as? StoreError, .unsupportedEffect) }
    }

    func testSupersededAndStaleLeaseDoNotReviveAndReceiptIsIdempotent() throws {
        let f = try fixture()
        let effect = try launch(f, "task")
        let original = try row(f.store, effect.id).payload
        let stale = try XCTUnwrap(f.store.claimEffect(owner: "old", leaseFor: -1, at: at))
        let current = try XCTUnwrap(f.store.claimEffect(owner: "new", leaseFor: 30, at: at))
        XCTAssertEqual(current.fencing, 2)
        let fact = finished(effect.id, .completed(summary: "Done"))
        XCTAssertThrowsError(try f.store.commitEffectResult(effectId: effect.id, leaseId: stale.leaseId, fact: fact, at: at)) { XCTAssertEqual($0 as? StoreError, .effectLeaseStale) }
        XCTAssertEqual(try task(f.store, "task").machine.state, .running)
        XCTAssertEqual(try row(f.store, effect.id).payload, original)
        let receipt = try f.store.commitEffectResult(effectId: effect.id, leaseId: current.leaseId, fact: fact, at: at)
        XCTAssertEqual(try task(f.store, "task").machine.state, .gating)
        XCTAssertEqual(try f.store.commitEffectResult(effectId: effect.id, leaseId: stale.leaseId, fact: fact, at: at), receipt)
        XCTAssertThrowsError(try f.store.commitEffectResult(effectId: effect.id, leaseId: current.leaseId, fact: finished(effect.id, .completed(summary: "Other")), at: at)) {
            XCTAssertEqual($0 as? StoreError, .effectResultConflict)
        }
        XCTAssertEqual(try task(f.store, "task").machine.state, .gating)
        XCTAssertThrowsError(try f.store.recordExternalFact(effectId: effect.id, leaseId: current.leaseId, fact: ExternalEffectFact(actionId: "other", phase: .finished, outcome: .acknowledged))) {
            XCTAssertEqual($0 as? StoreError, .effectResultConflict)
        }

        let other = try launch(f, "other")
        let otherPayload = try row(f.store, other.id).payload
        let lease = try XCTUnwrap(f.store.claimEffect(id: other.id, owner: "worker", leaseFor: 30, at: at))
        XCTAssertEqual(try f.store.execute(.init(command: .cancelTask(taskId: "other", keepBranch: true)), now: { self.at }).result, .ok)
        XCTAssertEqual(try row(f.store, other.id).status, "superseded")
        XCTAssertThrowsError(try f.store.commitEffectResult(effectId: other.id, leaseId: lease.leaseId, fact: finished(other.id, .completed(summary: "Revive")), at: at)) {
            XCTAssertEqual($0 as? StoreError, .effectSuperseded)
        }
        XCTAssertEqual(try task(f.store, "other").machine.state, .cancelled)
        XCTAssertEqual(try row(f.store, other.id).payload, otherPayload)
        let fresh = try KabanStore(path: f.path)
        XCTAssertEqual(try fresh.rowPayload(other.id), otherPayload)
        XCTAssertEqual(try task(fresh, "other").machine.state, .cancelled)
    }

    func testDatabaseFailureLeavesNoPartialTransitionAndPreservesFactAndPayload() throws {
        let f = try fixture()
        let effect = try launch(f, "task")
        let original = try row(f.store, effect.id).payload
        let lease = try XCTUnwrap(f.store.claimEffect(owner: "worker", leaseFor: 30, at: at))
        let fact = finished(effect.id, .completed(summary: "Done"))
        try f.store.recordExternalFact(effectId: effect.id, leaseId: lease.leaseId, fact: fact)
        try f.store.recordEffectDiagnostic(effectId: effect.id, leaseId: lease.leaseId, diagnostic: "still outside")
        let before = try task(f.store, "task")
        let seq = try f.store.snapshot().seq
        let inspection = try DatabaseQueue(path: f.path)
        try inspection.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_effect_result BEFORE INSERT ON event BEGIN SELECT RAISE(ABORT, 'injected'); END")
        }
        XCTAssertThrowsError(try f.store.commitEffectResult(effectId: effect.id, leaseId: lease.leaseId, fact: fact, at: at))
        XCTAssertEqual(try task(f.store, "task"), before)
        XCTAssertEqual(try f.store.snapshot().seq, seq)
        var failed = try row(f.store, effect.id)
        XCTAssertEqual(failed.status, "claimed")
        XCTAssertNil(failed.result)
        XCTAssertNil(failed.receipt)
        XCTAssertNotNil(failed.fact)
        XCTAssertEqual(failed.payload, original)
        XCTAssertEqual(failed.diagnostic, "still outside")
        try inspection.write { db in try db.execute(sql: "DROP TRIGGER fail_effect_result") }
        let receipt = try f.store.commitEffectResult(effectId: effect.id, leaseId: lease.leaseId, fact: fact, at: at)
        XCTAssertEqual(try task(f.store, "task").machine.state, .gating)
        XCTAssertEqual(receipt.effectId, effect.id)
        failed = try row(f.store, effect.id)
        XCTAssertEqual(failed.status, "acknowledged")
        XCTAssertEqual(failed.payload, original)
        XCTAssertThrowsError(try f.store.deliverFake(effectId: effect.id, result: .completed(summary: "Done"), at: at)) { XCTAssertEqual($0 as? StoreError, .unsupportedEffect) }
        let pendingGate = try XCTUnwrap(f.store.pendingEffectItems().first { if case .runGates = $0.effect { true } else { false } })
        XCTAssertThrowsError(try f.store.deliverFake(effectId: pendingGate.id, result: .gatesPassed, at: at)) { XCTAssertEqual($0 as? StoreError, .unsupportedEffect) }
        let log = f.root.appendingPathComponent("pass-log").path
        let lines = try f.store.runEffectPass(owner: "daemon", at: at, sideEffectLog: log)
        XCTAssertFalse(lines.contains { $0.contains(pendingGate.id) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: log))
        XCTAssertTrue(try f.store.pendingEffectItems().contains { $0.id == pendingGate.id })
    }

    func testDaemonPassClaimsLifecycleEffectsOnceAndReopenRepeatsTheReceipt() throws {
        let binary = try daemonBinary()
        let f = try fixture()
        let effect = try launch(f, "task")
        let pause = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
        XCTAssertEqual(try f.store.execute(.init(commandId: pause, command: .pauseTask(taskId: "task")), now: { at }).result, .ok)
        let pending = try f.store.pendingEffectItems()
        XCTAssertEqual(pending.map(\.effect).count, 1)
        guard case .killRun = pending[0].effect else { return XCTFail("expected killRun, got \(pending[0].effect)") }
        XCTAssertNotEqual(pending[0].id, effect.id)
        let log = f.root.appendingPathComponent("store.sqlite.side-effects").path
        let first = try runDaemon(binary, database: f.path)
        let second = try runDaemon(binary, database: f.path)
        let firstLines = effectLines(first.stderr)
        let secondLines = effectLines(second.stderr)
        XCTAssertEqual(first.exit, 0, first.stderr)
        XCTAssertEqual(second.exit, 0, second.stderr)
        XCTAssertEqual(firstLines, secondLines)
        XCTAssertEqual(firstLines.filter { $0.hasPrefix("effect claim ") }.count, 1)
        XCTAssertEqual(firstLines.filter { $0.contains("side-effect ") && $0.contains("after-commit") }.count, 1)
        XCTAssertEqual(firstLines.filter { $0.hasPrefix("effect receipt ") }.count, 1)
        XCTAssertFalse(firstLines.contains { $0.contains(effect.id) })
        let side = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertEqual(side.split(separator: "\n").count, 1)
        if let dir = ProcessInfo.processInfo.environment["KABAN_EFFECT_EVIDENCE"] {
            let root = URL(fileURLWithPath: dir, isDirectory: true)
            try first.stderr.write(to: root.appendingPathComponent("be-05-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-05-launch-2.log"), atomically: true, encoding: .utf8)
            try side.write(to: root.appendingPathComponent("be-05-side-effects.txt"), atomically: true, encoding: .utf8)
        }
        let reopened = try KabanStore(path: f.path)
        XCTAssertTrue(try reopened.pendingEffectItems().isEmpty)
        XCTAssertEqual(try task(reopened, "task").machine.state, .paused)
        XCTAssertEqual(try row(reopened, effect.id).status, "superseded")
    }

    func daemonBinary() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["KABAN_DAEMON"] {
            return URL(fileURLWithPath: env)
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        throw XCTSkip("Build KabanDaemon before the daemon pass launch")
    }

    struct DaemonOutput { var exit: Int32; var stderr: String }

    func runDaemon(_ binary: URL, database: String) throws -> DaemonOutput {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--effect-pass", "--stdio", "--database", database]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = error.fileHandleForReading.readDataToEndOfFile()
        return DaemonOutput(exit: process.terminationStatus, stderr: String(decoding: data, as: UTF8.self))
    }

    func effectLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { $0.hasPrefix("effect ") }
    }
}

private extension KabanStore {
    func rowPayload(_ id: String) throws -> Data {
        try database.read { db in try XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM effect WHERE id = ?", arguments: [id])) }
    }
}

private final class LeaseBox: @unchecked Sendable {
    let lock = NSLock()
    var values: [EffectLease?] = []
    var errors: [String] = []
    func add(_ value: EffectLease?) { lock.lock(); values.append(value); lock.unlock() }
    func fail(_ error: Error) { lock.lock(); errors.append(String(describing: error)); lock.unlock() }
}
