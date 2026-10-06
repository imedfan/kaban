import Foundation
import XCTest
import GRDB
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class FullPipelineSchedulerTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1234)
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
    struct Fixture { let root: URL; let store: KabanStore; let path: String; let projects: [ProjectID]; let repos: [URL] }
    func fixture(projects: Int = 1, content: String? = nil, settings: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path, store = try KabanStore(path: path)
        var ids: [ProjectID] = [], repos: [URL] = []
        for n in 0..<projects {
            let repo = root.appendingPathComponent("repo\(n)")
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
            try (content ?? yaml).write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
            try "skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
            try git(repo, ["init", "-b", "main"])
            try git(repo, ["config", "user.name", "Scheduler Test"]); try git(repo, ["config", "user.email", "scheduler@example.test"])
            try git(repo, ["add", "."]); try git(repo, ["commit", "-m", "Pipeline"])
            XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result, .ok)
            ids.append(try XCTUnwrap(store.getSnapshot().projects.first { $0.path == repo.path }?.id)); repos.append(repo)
        }
        if settings { try configure(store, max: 3) }
        return Fixture(root: root, store: store, path: path, projects: ids, repos: repos)
    }
    func git(_ repo: URL, _ args: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args; process.environment = DaemonGit.processEnvironment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(args)")
    }
    func configure(_ store: KabanStore, max: Int, quota: Bool = false) throws {
        _ = try store.setSettings(.init(maxConcurrentRuns: max, quotaOptions: .init(enabled: quota, consent: quota)), commandId: UUID(), at: at)
    }
    func create(_ f: Fixture, _ id: TaskID, stage: StageID = "backlog", project: Int = 0,
                state: TaskState = .queued(nil), retryAt: Date? = nil, priority: QueuePriority? = nil) throws {
        let reply = try f.store.execute(.init(command: .createTask(projectId: f.projects[project], title: id.rawValue, body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), now: { at }, makeTaskID: { id })
        XCTAssertEqual(reply.result, .taskCreated(id))
        XCTAssertTrue(try f.store.getTaskDetail(id).task.hasAcceptanceCriteria)
        // Explicit invocation/candidate fixtures; never delivered as fake production completions.
        if stage != "backlog" || state != .queued(nil) || priority != nil {
            try f.store.database.write { db in
                var task = try KabanStore.task(id, db: db)
                task.machine.stageId = stage; task.machine.state = state; task.machine.priority = priority
                task.machine.apply(to: &task.card, stage: task.pipeline.stage(stage)); task.card.retryAt = retryAt
                try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try KabanStore.encode(task), id.rawValue])
            }
        }
    }
    @discardableResult func start(_ f: Fixture, _ id: TaskID, run: RunID? = nil) throws -> DurableReceipt {
        try f.store.apply(.start(run ?? RunID(rawValue: id.rawValue + "-run")), taskId: id, commandId: UUID(), at: at)
    }
    @discardableResult func tick(_ store: KabanStore, at time: Date? = nil) throws -> TickReceipt {
        try store.tick(tickId: UUID(), runId: RunID(rawValue: UUID().uuidString), at: time ?? at)
    }
    func reload(_ f: Fixture, content: String) throws {
        try content.write(to: f.repos[0].appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try git(f.repos[0], ["add", ".kaban"]); try git(f.repos[0], ["commit", "-m", "Updated pipeline"])
        try f.store.refreshPipelines()
    }
    func testProductionFlowFreezesAgentGateAndMergeSpecsWithoutFakeExecution() throws {
        let f = try fixture(); try create(f, "task")
        XCTAssertEqual(try tick(f.store).transitions.last?.task.machine.stageId, "dev")
        var receipt = try tick(f.store); let run = try XCTUnwrap(receipt.transitions.last?.task.runSpecId)
        XCTAssertNotNil(try f.store.getRunSpec(run)?.source)
        let launch = try XCTUnwrap(f.store.pendingEffectItems().first { if case .startAgentRun = $0.effect { true } else { false } })
        XCTAssertThrowsError(try f.store.deliverFake(effectId: launch.id, result: .completed(summary: "Fake"), at: at))
        for stage: StageID in ["dev", "inspect"] {
            let current = try XCTUnwrap(f.store.snapshot().tasks.first?.runSpecId)
            _ = try f.store.apply(.completeStage(current, summary: "Invocation fixture"), taskId: "task", commandId: UUID(), at: at)
            _ = try f.store.apply(.gatesPassed, taskId: "task", commandId: UUID(), at: at)
            _ = try f.store.apply(.resultClean, taskId: "task", commandId: UUID(), at: at)
            receipt = try tick(f.store)
            XCTAssertEqual(try f.store.getRunSpec(current)?.stageId, stage)
        }
        XCTAssertEqual(receipt.transitions.last?.task.machine.state, .gating)
        let gateRun = try XCTUnwrap(receipt.transitions.last?.task.runSpecId)
        XCTAssertEqual(try f.store.getRunSpec(gateRun)?.stageId, "check")
        _ = try f.store.apply(.gatesPassed, taskId: "task", commandId: UUID(), at: at)
        _ = try f.store.apply(.resultClean, taskId: "task", commandId: UUID(), at: at)
        XCTAssertEqual(try tick(f.store).transitions.last?.task.machine.state, .waitingHuman(.review))
        XCTAssertEqual(try f.store.execute(.init(command: .approve(taskId: "task"))).result, .ok)
        receipt = try tick(f.store)
        XCTAssertEqual(receipt.transitions.last?.task.machine.stageId, "merge")
        let mergeRun = try XCTUnwrap(receipt.transitions.last?.task.runSpecId)
        XCTAssertEqual(try f.store.getRunSpec(mergeRun)?.stageId, "merge")
        XCTAssertTrue(try f.store.pendingEffectItems().contains { if case .startMerge = $0.effect { $0.runSpecId == mergeRun } else { false } })
        XCTAssertEqual(try f.store.getTaskDetail("task").runs.count, 2)
    }
    func testConcurrentProductionTicksRespectGlobalAndProjectCeilings() async throws {
        let f = try fixture(projects: 2), store = f.store, other = try KabanStore(path: f.path), clock = at
        for project in 0..<2 {
            _ = try store.execute(.init(command: .setProjectWeight(projectId: f.projects[project], weight: 1, maxRuns: 2)))
            for n in 0..<5 { try create(f, TaskID(rawValue: "\(project)-\(n)"), stage: "dev", project: project) }
        }
        let receipts = try await withThrowingTaskGroup(of: TickReceipt.self) { group in
            for n in 0..<10 {
                let current = n.isMultiple(of: 2) ? store : other
                group.addTask { try current.tick(tickId: UUID(), runId: RunID(rawValue: "run-\(n)"), at: clock) }
            }
            var values: [TickReceipt] = []; for try await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(receipts.flatMap(\.transitions).count, 3)
        let live = try store.getSnapshot().tasks.filter { $0.state == .running }
        XCTAssertEqual(live.count, 3)
        XCTAssertEqual(Set(live.map(\.projectId)), Set(f.projects))
        XCTAssertTrue(f.projects.allSatisfy { project in live.filter { $0.projectId == project }.count <= 2 })
        try configure(store, max: 1)
        XCTAssertTrue(try tick(store).transitions.isEmpty)
        XCTAssertEqual(try store.getSnapshot().tasks.filter { $0.state == .running }, live)
    }
    func testGateHumanMergeAndTerminalHaveIndependentCapacity() throws {
        let f = try fixture(); try configure(f.store, max: 1)
        for id: TaskID in ["agent", "agent-next"] { try create(f, id, stage: "dev") }
        _ = try start(f, "agent")
        for id: TaskID in ["gate-a", "gate-b", "gate-c"] { try create(f, id, stage: "check") }
        _ = try start(f, "gate-a"); _ = try start(f, "gate-b")
        XCTAssertThrowsError(try start(f, "gate-c"))
        for id: TaskID in ["merge-a", "merge-b"] { try create(f, id, stage: "merge") }
        _ = try start(f, "merge-a"); XCTAssertThrowsError(try start(f, "merge-b"))
        for id: TaskID in ["human-a", "human-b", "human-c"] { try create(f, id, stage: "review") }
        _ = try start(f, "human-a"); _ = try start(f, "human-b")
        XCTAssertThrowsError(try start(f, "human-c"))
        try create(f, "terminal", stage: "done")
        XCTAssertEqual(try tick(f.store).transitions.last?.task.machine.state, .done)
        XCTAssertTrue(try tick(f.store).transitions.isEmpty)
        let snapshot = try f.store.getSnapshot()
        XCTAssertEqual(snapshot.tasks.filter { $0.state == .running }.count, 1)
        XCTAssertEqual(snapshot.stageLoad.first { $0.stageId == "check" }?.wipUsed, 2)
        XCTAssertEqual(snapshot.stageLoad.first { $0.stageId == "merge" }?.wipUsed, 1)
        XCTAssertEqual(snapshot.stageLoad.first { $0.stageId == "review" }?.wipUsed, 2)
        XCTAssertEqual(try f.store.getTaskDetail("human-a").runs.count, 0)
    }
    func testHumanAdmissionAndCurrentRunsSurviveManualPauseShrinkAndReopen() throws {
        let f = try fixture(); try create(f, "live", stage: "dev"); _ = try start(f, "live")
        for id: TaskID in ["a", "b", "c"] { try create(f, id, stage: "review") }
        _ = try start(f, "a"); _ = try start(f, "b")
        XCTAssertEqual(try f.store.execute(.init(command: .pauseTask(taskId: "a"))).result, .ok)
        try reload(f, content: yaml.replacingOccurrences(of: "kind: human, wip: 2", with: "kind: human, wip: 1"))
        XCTAssertEqual(try f.store.execute(.init(command: .pauseProject(projectId: f.projects[0]))).result, .ok)
        XCTAssertTrue(try tick(f.store).transitions.isEmpty)
        XCTAssertEqual(try f.store.getTaskDetail("live").task.state, .running)
        let reopened = try KabanStore(path: f.path)
        _ = try reopened.execute(.init(command: .resumeTask(taskId: "a")))
        XCTAssertEqual(try reopened.getTaskDetail("a").task.state, .waitingHuman(.review))
        XCTAssertEqual(try reopened.getSnapshot().stageLoad.first { $0.stageId == "review" }?.wipUsed, 2)
        _ = try reopened.execute(.init(command: .resumeProject(projectId: f.projects[0])))
        XCTAssertTrue(try tick(reopened).transitions.isEmpty)
        _ = try reopened.execute(.init(command: .approve(taskId: "a")))
        _ = try tick(reopened) // merge a, while b still retains the sole human admission
        XCTAssertEqual(try reopened.getTaskDetail("c").task.state, .queued(nil))
        _ = try reopened.execute(.init(command: .approve(taskId: "b")))
        XCTAssertEqual(try tick(reopened).transitions.last?.task.card.id, "c")
    }
    func testPoolAndModelFlagsSkipCandidatesReleaseRetryWIPAndPreserveRuns() throws {
        let f = try fixture()
        try create(f, "om", stage: "dev", state: .retryWait(.crash), retryAt: at)
        try create(f, "cm", stage: "inspect")
        _ = try f.store.setSchedulerInputs(.init(flags: [.poolUsageExhausted(.om, resetsAt: nil)]), commandId: UUID(), at: at)
        XCTAssertEqual(try tick(f.store).transitions.last?.task.card.id, "cm")
        _ = try tick(f.store)
        XCTAssertEqual(try f.store.getTaskDetail("om").task.state, .queued(.quotaOm))
        XCTAssertEqual(try f.store.getSnapshot().stageLoad.first { $0.stageId == "dev" }?.wipUsed, 0)
        try create(f, "cm-flag", stage: "inspect")
        let flag = ModelFlag(modelId: "composer-fast", reason: .unavailable, requested: "composer-fast", since: at)
        _ = try f.store.setSchedulerInputs(.init(modelFlags: [flag]), commandId: UUID(), at: at)
        let selected = try tick(f.store)
        XCTAssertEqual(selected.transitions.last?.task.card.id, "om")
        XCTAssertEqual(try f.store.getTaskDetail("cm-flag").task.state, .queued(.modelFlag))
        XCTAssertEqual(try f.store.getTaskDetail("cm").task.state, .running)
        let reopened = try KabanStore(path: f.path)
        XCTAssertEqual(try reopened.getSnapshot().modelFlags, [flag])
        _ = try reopened.setSchedulerInputs(.init(), commandId: UUID(), at: at)
        XCTAssertEqual(try tick(reopened).transitions.last?.task.card.id, "cm-flag")
    }
    func testCooldownReplayAndRetryClockDoNotHoldTransactions() throws {
        let f = try fixture()
        try create(f, "retry", stage: "dev", state: .retryWait(.crash), retryAt: at.addingTimeInterval(30))
        _ = try f.store.setSchedulerInputs(.init(flags: [.rateLimited(cooldownUntil: at.addingTimeInterval(60), step: 1)]), commandId: UUID(), at: at)
        let token = UUID(), receipt = try f.store.tick(tickId: token, runId: "old", at: at)
        XCTAssertTrue(receipt.transitions.isEmpty)
        XCTAssertEqual(try f.store.tick(tickId: token, runId: "new", at: at.addingTimeInterval(61)), receipt)
        XCTAssertEqual(try f.store.getSnapshot().schedulerFlags.count, 1)
        XCTAssertEqual(try tick(f.store, at: at.addingTimeInterval(61)).transitions.last?.task.machine.state, .running)
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.isEmpty)
    }
    func testQuotaReserveCustomPoolAndUnknownOrStaleValues() throws {
        let f = try fixture(); try configure(f.store, max: 3, quota: true)
        try create(f, "live", stage: "dev"); _ = try start(f, "live")
        try create(f, "pending", stage: "dev")
        let rules = [ModelPoolRule(pattern: "explicit", pool: .cm, source: .user)] + ModelPoolRule.builtin
        let quota = QuotaState(cm: 89, om: 0, billingCycleEnd: nil, fetchedAt: at)
        _ = try f.store.setSchedulerInputs(.init(modelPoolRules: rules, quota: quota), commandId: UUID(), at: at)
        _ = try tick(f.store)
        XCTAssertEqual(try f.store.getTaskDetail("pending").task.state, .queued(.quotaCm)) // 11% minus 2% reserve <= 10%
        XCTAssertEqual(try f.store.getSnapshot().quota, quota)
        _ = try f.store.setSchedulerInputs(.init(modelPoolRules: rules, quota: .init(cm: nil, om: 0, billingCycleEnd: nil, fetchedAt: at)), commandId: UUID(), at: at)
        XCTAssertEqual(try tick(f.store).transitions.last?.task.card.id, "pending")
        try create(f, "stale", stage: "dev")
        _ = try f.store.setSchedulerInputs(.init(modelPoolRules: rules, quota: .init(cm: 100, om: 100, billingCycleEnd: nil, fetchedAt: at.addingTimeInterval(-1801))), commandId: UUID(), at: at)
        XCTAssertEqual(try tick(f.store).transitions.last?.task.card.id, "stale")
    }
    func testWeightedProductionFairnessAndDownstreamPriorityPersistAcrossReopen() throws {
        let f = try fixture(projects: 2)
        _ = try f.store.execute(.init(command: .setProjectWeight(projectId: f.projects[0], weight: 3, maxRuns: nil)))
        for project in 0..<2 {
            for n in 0..<30 { try create(f, TaskID(rawValue: "\(project)-\(n)"), stage: "dev", project: project) }
        }
        var chosen: [ProjectID] = []
        for n in 0..<24 {
            let current = n == 12 ? try KabanStore(path: f.path) : f.store
            let task = try XCTUnwrap(tick(current).transitions.last?.task)
            chosen.append(task.card.projectId)
            _ = try current.apply(.cancel(keepBranch: false), taskId: task.card.id, commandId: UUID(), at: at)
        }
        XCTAssertEqual(chosen.filter { $0 == f.projects[0] }.count, 18)
        XCTAssertEqual(chosen.filter { $0 == f.projects[1] }.count, 6)
    }
    func testCandidateOrderByStageReturnedAnsweredPriorityAndFIFO() throws {
        let f = try fixture(); try configure(f.store, max: 10)
        try create(f, "fifo", stage: "dev")
        try create(f, "priority", stage: "dev")
        _ = try f.store.execute(.init(command: .setPriority(taskId: "priority", priority: 100)))
        try create(f, "answered", stage: "dev", priority: .answered)
        try create(f, "returned", stage: "dev", priority: .returned)
        try create(f, "downstream", stage: "check")
        var choices: [TaskID] = []
        for _ in 0..<5 { choices.append(try XCTUnwrap(tick(f.store).transitions.last?.task.card.id)) }
        XCTAssertEqual(choices, ["downstream", "returned", "answered", "priority", "fifo"])
    }
    func testDownstreamOrderingFollowsGraphEvenWhenYAMLStagesAreReversed() throws {
        let chunks = yaml.components(separatedBy: "  -")
        let reversed = chunks[0] + chunks.dropFirst().reversed().map { "  -" + $0 }.joined()
        let f = try fixture(content: reversed)
        try create(f, "backlog"); try create(f, "dev", stage: "dev")
        try create(f, "review", stage: "review"); try create(f, "merge", stage: "merge")
        var choices: [TaskID] = []
        for _ in 0..<4 { choices.append(try XCTUnwrap(tick(f.store).transitions.last?.task.card.id)) }
        XCTAssertEqual(choices, ["merge", "review", "dev", "backlog"])
    }
    func testIdlePassesDoNotGrowReceiptsAndFailureRollsBackSpecOutboxAndCursor() throws {
        let f = try fixture()
        for _ in 0..<5 { XCTAssertTrue(try f.store.runSchedulerPass(at: at).isEmpty) }
        XCTAssertEqual(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tick") }, 0)
        try create(f, "task", stage: "dev")
        let before = try f.store.snapshot(), cursor = try f.store.database.read { try Data.fetchOne($0, sql: "SELECT payload FROM scheduler_cursor") }
        try f.store.database.write { try $0.execute(sql: "CREATE TRIGGER fail_tick BEFORE INSERT ON tick BEGIN SELECT RAISE(ABORT, 'fault'); END") }
        XCTAssertThrowsError(try tick(f.store))
        XCTAssertEqual(try f.store.snapshot().seq, before.seq)
        XCTAssertEqual(try f.store.getTaskDetail("task").task.state, .queued(nil))
        XCTAssertTrue(try f.store.pendingEffectItems().isEmpty)
        XCTAssertEqual(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM run_spec") }, 0)
        XCTAssertEqual(try f.store.database.read { try Data.fetchOne($0, sql: "SELECT payload FROM scheduler_cursor") }, cursor)
        try f.store.database.write { try $0.execute(sql: "DROP TRIGGER fail_tick") }
        XCTAssertEqual(try f.store.runSchedulerPass(at: at, budget: 1).count, 1)
        XCTAssertTrue(try f.store.runSchedulerPass(at: at).isEmpty)
    }
    func testInvalidMainRefusesHumanDecisionAndStopsStartsWhileRunCanFinish() throws {
        let f = try fixture()
        try create(f, "live", stage: "dev"); let live = try start(f, "live")
        try create(f, "review", stage: "review"); _ = try start(f, "review")
        try create(f, "new", stage: "dev")
        try reload(f, content: yaml.replacingOccurrences(of: "model: explicit", with: "model: auto"))
        XCTAssertTrue(try f.store.runSchedulerPass(at: at).isEmpty)
        let reply = try f.store.execute(.init(command: .approve(taskId: "review")))
        guard case .error(let error) = reply.result else { return XCTFail("Invalid main accepted approval") }
        XCTAssertEqual(error.code, "pipeline_invalid")
        XCTAssertEqual(try f.store.getTaskDetail("review").task.state, .waitingHuman(.review))
        XCTAssertEqual(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pipeline_deferred") }, 0)
        _ = try f.store.apply(.completeStage(try XCTUnwrap(live.task.runSpecId), summary: "Completed old invocation"), taskId: "live", commandId: UUID(), at: at)
        XCTAssertEqual(try f.store.getTaskDetail("live").task.state, .gating)
    }
    func testHostLoopWakesOnCommandAndTimerWithoutExplicitTick() async throws {
        let f = try fixture(settings: false), store = f.store
        try create(f, "task", stage: "dev", state: .retryWait(.crash), retryAt: Date().addingTimeInterval(0.2))
        let runtime = DaemonScheduler(store: store); defer { runtime.stop() }
        let service = DaemonService(store: store, wakeScheduler: { runtime.wake() })
        try configure(store, max: 1)
        _ = service.handle(.init(.command(.init(command: .resumeAll))))
        for _ in 0..<150 {
            if try store.getTaskDetail("task").task.state == .running { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try store.getTaskDetail("task").task.state, .running)
        XCTAssertEqual(try store.getTaskDetail("task").runs.count, 1)
    }
    func testIntakeAndMergeFlagsDoNotBlockOtherEligibleStages() throws {
        let f = try fixture()
        try create(f, "question", stage: "dev", state: .waitingHuman(.question))
        try create(f, "gate-question", stage: "check", state: .waitingHuman(.incident))
        try create(f, "backlog")
        try create(f, "merge-dirty", stage: "merge", state: .blocked(.mainDirty))
        try create(f, "merge-next", stage: "merge")
        try create(f, "human", stage: "review")
        try create(f, "gate", stage: "check")
        _ = try f.store.setSchedulerInputs(.init(flags: [.runnerUnavailable(.runnerAuth)]), commandId: UUID(), at: at)
        let snapshot = try f.store.getSnapshot()
        XCTAssertTrue(snapshot.schedulerFlags.contains(.intakePaused(f.projects[0])))
        XCTAssertTrue(snapshot.schedulerFlags.contains(.mergeBlocked(f.projects[0])))
        XCTAssertEqual(try tick(f.store).transitions.last?.task.card.id, "human")
        XCTAssertEqual(try tick(f.store).transitions.last?.task.card.id, "gate")
        XCTAssertTrue(try tick(f.store).transitions.isEmpty)
        XCTAssertEqual(try f.store.getTaskDetail("backlog").task.stageId, "backlog")
    }
    func testExistingRetryReservationSurvivesExecutionWIPShrink() throws {
        let f = try fixture()
        try create(f, "retry", stage: "dev", state: .retryWait(.crash), retryAt: at)
        try create(f, "live", stage: "dev"); _ = try start(f, "live")
        try create(f, "new", stage: "dev")
        try reload(f, content: yaml.replacingOccurrences(of: "wip: 4", with: "wip: 1"))
        XCTAssertEqual(try tick(f.store).transitions.last?.task.card.id, "retry")
        XCTAssertEqual(try f.store.getSnapshot().stageLoad.first { $0.stageId == "dev" }?.wipUsed, 2)
        XCTAssertTrue(try tick(f.store).transitions.isEmpty)
        XCTAssertEqual(try f.store.getTaskDetail("new").task.state, .queued(nil))
    }
    func testPendingPipelineIntentBlocksStartsAndLabelsHaveFiniteBudget() throws {
        let f = try fixture(); try create(f, "task", stage: "dev")
        try f.store.database.write { db in
            try db.execute(sql: "INSERT INTO pipeline_operation(id, request, project_id, payload) VALUES (?, ?, ?, ?)", arguments: [UUID().uuidString, Data(), f.projects[0].rawValue, Data()])
        }
        XCTAssertTrue(try f.store.runSchedulerPass(at: at).isEmpty)
        try f.store.database.write { try $0.execute(sql: "DELETE FROM pipeline_operation") }
        for n in 0..<40 { try create(f, TaskID(rawValue: "blocked-\(n)"), stage: "dev") }
        let flag = ModelFlag(modelId: "explicit", reason: .unavailable, requested: "explicit", since: at)
        _ = try f.store.setSchedulerInputs(.init(modelFlags: [flag]), commandId: UUID(), at: at)
        let receipt = try tick(f.store)
        XCTAssertEqual(receipt.transitions.count, 32)
        let token = receipt.tickId
        XCTAssertEqual(try f.store.tick(tickId: token, runId: "different", at: Date()), receipt)
        XCTAssertEqual(try tick(f.store).transitions.count, 9)
        XCTAssertTrue(try f.store.runSchedulerPass(at: at).isEmpty)
    }
}
