import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class ModelProbeTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let clean = "{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"Fake Model\"}\n{\"type\":\"result\",\"subtype\":\"success\"}\n"

    struct Fixture { let root: URL; let path: String; let store: KabanStore }

    func fixture(wip: Int = 8, attempts: Int = 3) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-model-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("db.sqlite").path
        let store = try KabanStore(path: path)
        addTeardownBlock {
            for record in (try? store.database.read({ try KabanStore.probeProcesses($0) })) ?? [] where !record.finished && record.handlePID > 1 {
                _ = try? ProcessGroup.stop(pid: record.handlePID, processGroup: record.handlePID, birth: record.birth)
                _ = ProcessGroup.poll(record.handlePID)
            }
            try? FileManager.default.removeItem(at: root)
        }
        var pipeline = try ManagedEngineFixture.pipeline()
        pipeline.stages[1].wip = wip
        pipeline.stages[1].retry.maxAttempts = attempts
        pipeline.stages[1].retry.backoffSeconds = attempts == 1 ? [] : [30]
        _ = try store.registerProject(.init(id: "p", name: "P", path: "/never-read", maxRuns: 1, mascotSeed: "p"), pipeline: pipeline, commandId: UUID(), at: at)
        _ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        XCTAssertTrue(try store.replaceCatalog(text: "fake\tFake Model\ncomposer-test\tComposer Model", at: at))
        return Fixture(root: root, path: path, store: store)
    }

    func task(_ id: TaskID, _ store: KabanStore) throws -> DurableTask {
        try store.database.read { try KabanStore.task(id, db: $0) }
    }

    func start(_ id: TaskID, _ f: Fixture, model: ModelID? = nil) throws {
        XCTAssertEqual(try f.store.execute(.init(command: .createTask(projectId: "p", title: id.rawValue, body: "Task\n\n## Критерии приёмки\n- [ ] OK")), now: { at }, makeTaskID: { id }).result, .taskCreated(id))
        _ = try f.store.apply(.start(RunID(rawValue: "intake-\(id.rawValue)")), taskId: id, commandId: UUID(), at: at)
        if let model { _ = try f.store.execute(.init(command: .setModelOverride(taskId: id, stageId: "agent", model: model)), now: { at }) }
        // The fixture's one-project process limit is deliberately lifted for setup only.
        try f.store.database.write { db in
            var project = try KabanStore.project("p", db: db)
            project.summary.maxRuns = 8
            try db.execute(sql: "UPDATE project SET payload = ? WHERE id = 'p'", arguments: [try KabanStore.encode(project)])
        }
        _ = try f.store.apply(.start(RunID(rawValue: "run-\(id.rawValue)")), taskId: id, commandId: UUID(), at: at)
    }

    func silent(_ id: TaskID, _ f: Fixture) throws {
        _ = try f.store.apply(.runFailed(RunID(rawValue: "run-\(id.rawValue)"), .silentExit), taskId: id, commandId: UUID(), at: at)
    }

    func cli(_ f: Fixture, output: String? = nil, stderr: String = "", wait: Bool = false, exit: Int = 0) throws {
        let file = f.root.appendingPathComponent("cursor-agent")
        let text = output ?? clean
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        case "$1" in
          --version) echo 1.0; exit 0;;
          status) echo ready; exit 0;;
          --list-models) printf 'fake\\tFake Model\\ncomposer-test\\tComposer Model\\n'; exit 0;;
        esac
        printf '%s\\n' "$@" >> \(q(f.root.appendingPathComponent("argv").path))
        \(wait ? "while [ ! -f " + q(f.root.appendingPathComponent("release").path) + " ]; do /bin/sleep 0.02; done" : "")
        printf '%s' \(q(text))
        printf '%s' \(q(stderr)) >&2
        exit \(exit)
        """
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        try f.store.setRunnerExecutable(file.path)
    }

    func pass(_ f: Fixture, _ when: Date? = nil, store: KabanStore? = nil) throws {
        try (store ?? f.store).runModelProbePass(at: when ?? at, workspaceRoot: f.root.path)
    }

    func finish(_ f: Fixture, _ when: Date? = nil, store: KabanStore? = nil) throws {
        let selected = store ?? f.store
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try pass(f, when, store: selected)
            if try selected.database.read({ try KabanStore.probeProcesses($0).allSatisfy(\.finished) }) { return }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        XCTFail("Probe did not finish")
    }

    func records(_ f: Fixture) throws -> [ModelProbeProcess] {
        try f.store.database.read { try KabanStore.probeProcesses($0) }
    }

    func testCleanProbeChargesBothSilentRunsOnceWithoutNewHistoryOrWIP() throws {
        let f = try fixture()
        for id: TaskID in ["a", "b"] { try start(id, f); try silent(id, f) }
        let load = try f.store.database.read { try KabanStore.stageLoads($0) }
        try cli(f)
        try finish(f)
        XCTAssertEqual(try records(f).count, 1)
        for id: TaskID in ["a", "b"] {
            let current = try task(id, f.store)
            XCTAssertEqual(current.machine.state, .retryWait(.crash))
            XCTAssertEqual(current.machine.attemptsUsed, 1)
            XCTAssertEqual(current.machine.runsSinceHuman, 1)
            XCTAssertEqual(current.card.retryAt, at.addingTimeInterval(30))
            let runs = try f.store.getTaskDetail(id).runs
            XCTAssertEqual(runs.count, 1)
            XCTAssertTrue(try XCTUnwrap(runs.first).countsTowardLimits)
        }
        XCTAssertEqual(try f.store.database.read { try KabanStore.stageLoads($0) }, load)
        let seq = try f.store.getSnapshot().seq
        try finish(f, at.addingTimeInterval(2))
        XCTAssertEqual(try f.store.getSnapshot().seq, seq)
        let argv = try String(contentsOf: f.root.appendingPathComponent("argv"), encoding: .utf8)
        XCTAssertTrue(argv.contains("--model\nfake\n"))
        XCTAssertFalse(argv.contains("--force")); XCTAssertFalse(argv.contains("--resume"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(records(f).first).directory))
    }

    func testWIPOneAndProjectSlotDoNotBlockProbeAndLastAttemptWaitsForHuman() throws {
        let f = try fixture(wip: 1, attempts: 1)
        try start("a", f); try silent("a", f)
        let load = try f.store.database.read { try KabanStore.stageLoads($0) }
        try cli(f); try finish(f)
        XCTAssertEqual(try task("a", f.store).machine.state, .waitingHuman(.retriesExhausted))
        XCTAssertEqual(try task("a", f.store).machine.attemptsUsed, 1)
        XCTAssertEqual(load.first { $0.stageId == "agent" }?.wipUsed, 1)
        XCTAssertEqual(try f.store.database.read { try KabanStore.stageLoads($0) }.first { $0.stageId == "agent" }?.wipUsed, 0)
    }

    func testLimitProbeDoesNotChargeAndOneObservationDoesNotEscalateTwice() throws {
        let f = try fixture()
        for id: TaskID in ["a", "b"] { try start(id, f); try silent(id, f) }
        try cli(f, output: "", stderr: "Too many requests", exit: 1); try finish(f)
        for id: TaskID in ["a", "b"] {
            XCTAssertEqual(try task(id, f.store).machine.state, .retryWait(.rateLimit))
            XCTAssertEqual(try task(id, f.store).machine.attemptsUsed, 0)
            XCTAssertEqual(try task(id, f.store).machine.runsSinceHuman, 0)
        }
        XCTAssertEqual(try f.store.getSnapshot().schedulerFlags, [.rateLimited(cooldownUntil: at.addingTimeInterval(900), step: 1)])
    }

    func testThrottleUsesActualStartAndSurvivesReopen() throws {
        let f = try fixture()
        try start("a", f); try silent("a", f); try cli(f, output: "unrecognized", wait: true)
        try pass(f)
        let first = try XCTUnwrap(records(f).first)
        let reopened = try KabanStore(path: f.path)
        try pass(f, at.addingTimeInterval(20), store: reopened)
        XCTAssertEqual(try records(f).first?.id, first.id)
        try Data().write(to: f.root.appendingPathComponent("release"))
        try finish(f, at.addingTimeInterval(20), store: reopened)
        XCTAssertEqual(try task("a", reopened).machine.attemptsUsed, 0)
        try pass(f, at.addingTimeInterval(599), store: reopened)
        XCTAssertEqual(try records(f).first?.id, first.id)
        try finish(f, at.addingTimeInterval(600), store: reopened)
        XCTAssertNotEqual(try records(f).first?.id, first.id)
    }

    func testProbeHoldsFourthMacSlotAndWaitsWhenAllFourAreReserved() throws {
        let f = try fixture()
        try start("silent", f); try silent("silent", f)
        for id: TaskID in ["a", "b", "c", "d"] { try start(id, f) }
        try cli(f, wait: true)
        try pass(f)
        XCTAssertTrue(try records(f).isEmpty)
        _ = try f.store.apply(.pause, taskId: "d", commandId: UUID(), at: at)
        try pass(f)
        let record = try XCTUnwrap(records(f).first)
        XCTAssertFalse(record.finished)
        XCTAssertEqual(try f.store.database.read { try KabanStore.agentProcessLoad($0) }, 4)
        _ = try f.store.apply(.resume, taskId: "d", commandId: UUID(), at: at)
        XCTAssertThrowsError(try f.store.apply(.start("new-d"), taskId: "d", commandId: UUID(), at: at))
        for id: TaskID in ["a", "b", "c"] { XCTAssertEqual(try task(id, f.store).machine.state, .running) }
        try Data().write(to: f.root.appendingPathComponent("release")); try finish(f)
        _ = try f.store.apply(.start("new-d"), taskId: "d", commandId: UUID(), at: at)
        XCTAssertEqual(try task("d", f.store).machine.state, .running)
    }

    func testUnknownUsagePersistsAfterSevenHoursWithoutCleanProbeAndClearsOnCleanProbe() throws {
        let f = try fixture()
        try start("a", f)
        _ = try f.store.apply(.runFailed("run-a", .usageExhausted(.om)), taskId: "a", commandId: UUID(), at: at)
        try cli(f, output: "", stderr: "usage limit", exit: 1)
        try pass(f, at.addingTimeInterval(21_599))
        XCTAssertTrue(try records(f).isEmpty)
        _ = try f.store.tick(tickId: UUID(), runId: "tick", at: at.addingTimeInterval(25_200))
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains(.poolUsageExhausted(.om, resetsAt: nil)))
        try finish(f, at.addingTimeInterval(25_200))
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains(.poolUsageExhausted(.om, resetsAt: nil)))
        try cli(f)
        try pass(f, at.addingTimeInterval(25_800))
        XCTAssertEqual(try records(f).first?.startedAt, at.addingTimeInterval(25_200))
        try finish(f, at.addingTimeInterval(46_800))
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.isEmpty)
    }

    func testManualUsageClearIsScopedDurableAndReplayedBeforeClock() throws {
        let f = try fixture()
        _ = try f.store.setSchedulerInputs(.init(flags: [.usageExhaustedUnknown(resetsAt: nil), .poolUsageExhausted(.cm, resetsAt: nil)]), commandId: UUID(), at: at)
        let envelope = CommandEnvelope(command: .clearUsageFlag(pool: nil))
        let reply = try f.store.execute(envelope, now: { at })
        XCTAssertEqual(reply.result, .ok)
        XCTAssertEqual(try f.store.getSnapshot().schedulerFlags, [.poolUsageExhausted(.cm, resetsAt: nil)])
        XCTAssertEqual(try f.store.execute(envelope, now: { self.at.addingTimeInterval(60) }), reply)
        let reopened = try KabanStore(path: f.path)
        XCTAssertEqual(try reopened.getSnapshot().schedulerFlags, [.poolUsageExhausted(.cm, resetsAt: nil)])
        XCTAssertEqual(DaemonService.capabilities.commands.first { $0.name == "clearUsageFlag" }?.support, .supported)
    }

    func testModelFlagRequiresConfirmedInitAndCatalogReturnAlsoClearsUnavailable() throws {
        let f = try fixture()
        _ = try f.store.setSchedulerInputs(.init(modelFlags: [.init(modelId: "fake", reason: .unavailable, requested: "Fake Model", since: at)]), commandId: UUID(), at: at)
        try cli(f, output: clean.replacingOccurrences(of: "Fake Model", with: "Composer Model")); try finish(f)
        XCTAssertEqual(try f.store.getSnapshot().modelFlags.count, 1)
        try cli(f); try finish(f, at.addingTimeInterval(600))
        XCTAssertTrue(try f.store.getSnapshot().modelFlags.isEmpty)
        _ = try f.store.setSchedulerInputs(.init(modelFlags: [.init(modelId: "fake", reason: .unavailable, requested: "Fake Model", since: at)]), commandId: UUID(), at: at)
        XCTAssertTrue(try f.store.replaceCatalog(text: "fake\tFake Model\ncomposer-test\tComposer Model", at: at))
        XCTAssertTrue(try f.store.getSnapshot().modelFlags.isEmpty)
    }

    func testUnconfirmedAndLateResultNeverChargeCancelledTask() throws {
        let f = try fixture()
        try start("a", f); try silent("a", f); try cli(f, wait: true)
        try pass(f)
        _ = try f.store.apply(.cancel(keepBranch: false), taskId: "a", commandId: UUID(), at: at)
        try Data().write(to: f.root.appendingPathComponent("release")); try finish(f)
        XCTAssertEqual(try task("a", f.store).machine.state, .cancelled)
        XCTAssertEqual(try task("a", f.store).machine.attemptsUsed, 0)
        // No success exit or missing init/result can clear a flag or charge a silent task.
        for (output, code) in [("", Int32(0)), ("{\"type\":\"result\"}", 0), (clean, 1), ("invalid", 0)] {
            XCTAssertNil(KabanStore.probeOutcome(stdout: output, stderr: "", code: code, model: "fake", pool: .om, catalog: try f.store.modelCatalog()))
        }
    }

    func testSilentOverrideProbesFrozenRequestedModel() throws {
        let f = try fixture()
        try start("a", f, model: "composer-test"); try silent("a", f)
        _ = try f.store.execute(.init(command: .setModelOverride(taskId: "a", stageId: "agent", model: "fake")), now: { at })
        try cli(f, output: clean.replacingOccurrences(of: "Fake Model", with: "Composer Model")); try finish(f)
        XCTAssertEqual(try records(f).first?.model, "composer-test")
        XCTAssertEqual(try task("a", f.store).machine.attemptsUsed, 1)
    }
    func testTimeoutStopsOnlyProbeAndDoesNotChargeAttempt() throws {
        let f = try fixture()
        try start("a", f); try silent("a", f); try cli(f, wait: true)
        try pass(f)
        let before = try XCTUnwrap(records(f).first)
        try finish(f, at.addingTimeInterval(61))
        XCTAssertFalse(ProcessGroup.isExecuting(before.handlePID, birth: before.birth))
        XCTAssertNil(try records(f).first?.outcome)
        XCTAssertEqual(try task("a", f.store).machine.state, .retryWait(.silentExit))
        XCTAssertEqual(try task("a", f.store).machine.attemptsUsed, 0)
    }

    func testCleanProbeCannotClearNewUsageFailureWhileItWasRunning() throws {
        let f = try fixture()
        try start("a", f); try start("b", f)
        _ = try f.store.apply(.runFailed("run-a", .usageExhausted(.om)), taskId: "a", commandId: UUID(), at: at)
        try cli(f, wait: true)
        try pass(f, at.addingTimeInterval(21_600))
        _ = try f.store.apply(.runFailed("run-b", .usageExhausted(.om)), taskId: "b", commandId: UUID(), at: at.addingTimeInterval(21_601))
        try Data().write(to: f.root.appendingPathComponent("release"))
        try finish(f, at.addingTimeInterval(21_602))
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains(.poolUsageExhausted(.om, resetsAt: nil)))
    }

    func testProbeResultRollsBackAndRetriesAtomicallyAfterStoreFailure() throws {
        let f = try fixture()
        for id: TaskID in ["a", "b"] { try start(id, f); try silent(id, f) }
        try cli(f, wait: true); try pass(f)
        try f.store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_probe_command BEFORE INSERT ON command BEGIN SELECT RAISE(ABORT, 'test write failure'); END")
        }
        try Data().write(to: f.root.appendingPathComponent("release"))
        let deadline = Date().addingTimeInterval(3)
        var failed = false
        while Date() < deadline && !failed {
            do { try pass(f) } catch { failed = true }
            if !failed { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertTrue(failed)
        for id: TaskID in ["a", "b"] { XCTAssertEqual(try task(id, f.store).machine.attemptsUsed, 0) }
        XCTAssertEqual(try records(f).first?.outcome, .clean)
        XCTAssertFalse(try XCTUnwrap(records(f).first).finished)
        try f.store.database.write { try $0.execute(sql: "DROP TRIGGER reject_probe_command") }
        let reopened = try KabanStore(path: f.path)
        try finish(f, store: reopened)
        for id: TaskID in ["a", "b"] { XCTAssertEqual(try task(id, reopened).machine.attemptsUsed, 1) }
    }

    func testNormalRuntimePassExecutesProbeWithoutTaskRunner() throws {
        let f = try fixture()
        try start("a", f); try silent("a", f); try cli(f)
        // Keep the task in backoff; runRuntimePass polls the real configured probe process.
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try f.store.runRuntimePass(at: at, workspaceRoot: f.root.path)
            if try task("a", f.store).machine.attemptsUsed == 1 { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        XCTAssertEqual(try task("a", f.store).machine.state, .retryWait(.crash))
        XCTAssertEqual(try f.store.getTaskDetail("a").runs.count, 1)
    }

    func testKnownResetBlocksProbeAndUsageProbeKeepsParsedReset() throws {
        let f = try fixture()
        try start("a", f); try silent("a", f); try cli(f, output: "", stderr: "usage limit resets 2026-10-06T12:00:00Z", exit: 1)
        _ = try f.store.setSchedulerInputs(.init(flags: [.poolUsageExhausted(.om, resetsAt: at.addingTimeInterval(60))]), commandId: UUID(), at: at)
        try pass(f); XCTAssertTrue(try records(f).isEmpty)
        try finish(f, at.addingTimeInterval(60))
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains(.poolUsageExhausted(.om, resetsAt: Date(timeIntervalSince1970: 1_791_288_000))))
        XCTAssertEqual(try task("a", f.store).machine.attemptsUsed, 0)
    }

    func testUnavailableAndLoggedOutProbeRouteWithoutCharging() throws {
        for text in ["resource_exhausted", "not logged in"] {
            let f = try fixture()
            try start("a", f); try silent("a", f)
            try cli(f, output: "", stderr: text, exit: 1); try finish(f)
            XCTAssertEqual(try task("a", f.store).machine.attemptsUsed, 0)
            if text == "resource_exhausted" {
                XCTAssertEqual(try task("a", f.store).machine.state, .queued(.modelFlag))
                XCTAssertEqual(try f.store.getSnapshot().modelFlags.first?.modelId, "fake")
            } else {
                XCTAssertEqual(try task("a", f.store).machine.state, .retryWait(.runnerAuth))
                XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains(.runnerUnavailable(.runnerAuth)))
            }
        }
    }

    func testAdditiveMigrationPreservesLegacyTaskAndCommandReceipt() throws {
        let f = try fixture()
        try start("a", f); try silent("a", f)
        let envelope = CommandEnvelope(command: .resumeAfterRateLimit)
        let reply = try f.store.execute(envelope, now: { at })
        let before = try f.store.getSnapshot()
        try f.store.database.write { db in
            try db.execute(sql: "DROP TABLE model_probe_process")
            try db.execute(sql: "DROP TABLE usage_probe_due")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'model_probe_process_v24'")
        }
        let reopened = try KabanStore(path: f.path)
        XCTAssertEqual(try reopened.getSnapshot(), before)
        XCTAssertEqual(try reopened.execute(envelope), reply)
        XCTAssertEqual(try reopened.modelProbes().count, 1)
        XCTAssertTrue(try reopened.database.read { try KabanStore.probeProcesses($0).isEmpty })
    }

    func testRapidCleanExitsAlwaysDeliverTheirResult() throws {
        for index in 0..<20 {
            let f = try fixture()
            try start("a", f); try silent("a", f); try cli(f)
            try finish(f)
            XCTAssertEqual(try records(f).first?.outcome, .clean, "Exit \(index)")
            XCTAssertEqual(try task("a", f.store).machine.attemptsUsed, 1, "Exit \(index)")
        }
    }

}
