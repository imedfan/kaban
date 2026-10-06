import XCTest
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

final class ModelCatalogStoreTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testAutoIsRejectedAndAnOverrideDoesNotChangeAnotherTask() throws {
        let fixture = try store()
        _ = try fixture.store.execute(.init(command: .createTask(projectId: "p", title: "A", body: body)), now: { at }, makeTaskID: { "a" })
        _ = try fixture.store.execute(.init(command: .createTask(projectId: "p", title: "B", body: body)), now: { at }, makeTaskID: { "b" })
        let yaml = """
        version: 1
        stages:
          - id: queue
            name: Queue
            kind: queue
            on_success: agent
          - id: agent
            name: Agent
            kind: agent
            agent: {harness: cursor-cli, model: auto, skill: test.md, permissions: write, mcp: [kaban]}
            on_success: done
          - id: done
            name: Done
            kind: terminal
        """
        let validation = try fixture.store.execute(.init(command: .validatePipeline(projectId: "p", content: yaml)), now: { at })
        guard case .validationIssues(let issues) = validation.result else {
            return XCTFail("Expected validation issues, got \(validation.result)")
        }
        XCTAssertTrue(issues.contains { $0.code == ValidationCode.modelAutoForbidden })
        let refused = try fixture.store.execute(.init(command: .setModelOverride(taskId: "a", stageId: "agent", model: "auto")), now: { at })
        guard case .error(let error) = refused.result else { return XCTFail("Expected refusal") }
        XCTAssertEqual(error.code, ValidationCode.modelAutoForbidden)
        XCTAssertEqual(try fixture.store.resolvedModel(taskId: "a", stageId: "agent")?.rawValue, "fake")
        XCTAssertEqual(try fixture.store.execute(.init(command: .setModelOverride(taskId: "a", stageId: "agent", model: "gpt-5")), now: { at }).result, .ok)
        XCTAssertEqual(try fixture.store.resolvedModel(taskId: "a", stageId: "agent")?.rawValue, "gpt-5")
        XCTAssertEqual(try fixture.store.resolvedModel(taskId: "b", stageId: "agent")?.rawValue, "fake")
        let reopened = try KabanStore(path: fixture.path)
        XCTAssertEqual(try reopened.resolvedModel(taskId: "a", stageId: "agent")?.rawValue, "gpt-5")
        XCTAssertEqual(try reopened.resolvedModel(taskId: "b", stageId: "agent")?.rawValue, "fake")
    }

    func testUnknownNameStaysUnconfirmedAndAKnownMismatchIsNotSuccess() throws {
        let fixture = try store()
        XCTAssertTrue(try fixture.store.replaceCatalog(text: "fake\tFake Model\nother\tOther Model\n", at: at))
        XCTAssertFalse(try fixture.store.replaceCatalog(text: "Error: Authentication required\n", at: at))
        XCTAssertEqual(try fixture.store.modelCatalog().map(\.id.rawValue).sorted(), ["fake", "other"])
        _ = try fixture.store.execute(.init(command: .createTask(projectId: "p", title: "A", body: body)), now: { at }, makeTaskID: { "a" })
        _ = try fixture.store.apply(.start("intake-a"), taskId: "a", commandId: UUID(), at: at)
        _ = try fixture.store.apply(.start("run-a"), taskId: "a", commandId: UUID(), at: at)
        let before = try task("a", fixture.store)
        XCTAssertEqual(try fixture.store.observeModelInit(taskId: "a", runId: "run-a", actualName: "Mystery", fallback: nil, commandId: UUID(), at: at), .unconfirmed)
        XCTAssertEqual(try fixture.store.observeModelInit(taskId: "a", runId: "run-a", actualName: "Same", fallback: nil, commandId: UUID(), at: at), .unconfirmed)
        XCTAssertFalse(try fixture.store.modelCatalog().contains { $0.name == "Mystery" || $0.name == "Same" })
        let command = UUID()
        XCTAssertEqual(try fixture.store.observeModelInit(taskId: "a", runId: "run-a", actualName: "Mystery", fallback: "secret", commandId: command, at: at), .unconfirmed)
        XCTAssertEqual(try fixture.store.observeModelInit(taskId: "a", runId: "run-a", actualName: "Mystery", fallback: "secret", commandId: command, at: at), .unconfirmed)
        XCTAssertEqual(try fixture.store.getTaskDetail("a").feed.filter { $0.kind == "model_unconfirmed" }.count, 3)
        XCTAssertEqual(try task("a", fixture.store).machine.state, before.machine.state)
        XCTAssertEqual(try fixture.store.observeModelInit(taskId: "a", runId: "run-a", actualName: "Other Model", fallback: "fallback-model", commandId: UUID(), at: at), .substituted(requestedName: "Fake Model", actualName: "Other Model"))
        let substituted = try task("a", fixture.store)
        XCTAssertEqual(substituted.machine.state, .waitingHuman(.modelSubstituted))
        XCTAssertEqual(substituted.machine.attemptsUsed, before.machine.attemptsUsed)
        XCTAssertEqual(substituted.machine.runsSinceHuman, before.machine.runsSinceHuman - 1)
        _ = try fixture.store.apply(.completeStage("run-a", summary: "Done"), taskId: "a", commandId: UUID(), at: at)
        XCTAssertEqual(try task("a", fixture.store).machine.state, .waitingHuman(.modelSubstituted))
        let runs = try fixture.store.getTaskDetail("a").runs
        XCTAssertTrue(runs.contains { $0.endReason == .modelSubstituted && $0.countsTowardLimits == false })
        XCTAssertFalse(runs.contains { $0.status == .succeeded || $0.endReason == .completed })
        let flag = try XCTUnwrap(fixture.store.getSnapshot().modelFlags.first { $0.modelId.rawValue == "fake" })
        XCTAssertEqual(flag.reason, .substituted)
        XCTAssertEqual(flag.requested, "Fake Model")
        XCTAssertEqual(flag.actual, "Other Model")
        XCTAssertEqual(flag.fallbackModel, "fallback-model")
        let reopened = try KabanStore(path: fixture.path)
        XCTAssertEqual(try reopened.getSnapshot().modelFlags, try fixture.store.getSnapshot().modelFlags)
        XCTAssertEqual(try task("a", reopened).machine.attemptsUsed, substituted.machine.attemptsUsed)
        XCTAssertEqual(try task("a", reopened).machine.runsSinceHuman, substituted.machine.runsSinceHuman)
        XCTAssertEqual(try reopened.getTaskDetail("a").task.state, .waitingHuman(.modelSubstituted))
    }

    func testAMissingModelBlocksOnlyStagesThatUseIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 2, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at)
        _ = try store.registerProject(ProjectSummary(id: "cm", name: "Cm", path: "/never-read-cm", mascotSeed: "cm"), pipeline: try pipeline(model: "composer-2"), commandId: UUID(), at: at)
        _ = try store.registerProject(ProjectSummary(id: "om", name: "Om", path: "/never-read-om", mascotSeed: "om"), pipeline: try pipeline(model: "gpt-5"), commandId: UUID(), at: at)
        _ = try store.execute(.init(command: .createTask(projectId: "cm", title: "Cm", body: body)), now: { at }, makeTaskID: { "cm-task" })
        _ = try store.execute(.init(command: .createTask(projectId: "om", title: "Om", body: body)), now: { at }, makeTaskID: { "om-task" })
        XCTAssertTrue(try store.replaceCatalog(text: "composer-2\tComposer 2\ngpt-5\tGPT-5\n", at: at))
        XCTAssertTrue(try store.replaceCatalog(text: "gpt-5\tGPT-5\n", at: at))
        let flags = try store.getSnapshot().modelFlags
        XCTAssertEqual(flags.map(\.modelId.rawValue), ["composer-2"])
        XCTAssertEqual(flags.first?.reason, .unavailable)
        let cm = try task("cm-task", store)
        let om = try task("om-task", store)
        XCTAssertFalse(try store.database.read { try KabanStore.canStart(cm, at: self.at, db: $0) })
        XCTAssertTrue(try store.database.read { try KabanStore.canStart(om, at: self.at, db: $0) })
        let listed = try store.execute(.init(command: .listModels), now: { at })
        guard case .models(let models) = listed.result else { return XCTFail("Expected models") }
        XCTAssertEqual(models.map(\.id.rawValue), ["composer-2", "gpt-5"])
        XCTAssertEqual(models.first { $0.id.rawValue == "composer-2" }?.missingSince, at)
        XCTAssertTrue(models.contains { $0.id.rawValue == "gpt-5" && $0.needsReview && $0.pool == .om })
        XCTAssertEqual(try store.execute(.init(command: .setModelPoolRule(pattern: "composer-*", pool: .cm)), now: { at }).result, .ok)
        let reviewed = try store.modelCatalog().first { $0.id.rawValue == "composer-2" }
        XCTAssertEqual(reviewed?.pool, .cm)
        XCTAssertEqual(reviewed?.needsReview, false)
        XCTAssertEqual(try store.execute(.init(command: .clearModelFlag(modelId: "composer-2")), now: { at }).result, .ok)
        XCTAssertTrue(try store.database.read { try KabanStore.canStart(cm, at: self.at, db: $0) })
    }

    private let body = "Task\n\n## Критерии приёмки\n- [ ] Ready\n"

    private func store() throws -> (path: String, store: KabanStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        _ = try store.registerProject(ProjectSummary(id: "p", name: "P", path: "/never-read", mascotSeed: "p"), pipeline: try ManagedEngineFixture.pipeline(), commandId: UUID(), at: at)
        _ = try store.setSettings(GlobalSettings(maxConcurrentRuns: 2, quotaOptions: QuotaOptions(enabled: false, consent: false)), commandId: UUID(), at: at)
        return (path, store)
    }

    private func pipeline(model: String) throws -> PipelineConfig {
        var pipeline = try ManagedEngineFixture.pipeline()
        let index = try XCTUnwrap(pipeline.stages.firstIndex { $0.kind == .agent })
        pipeline.stages[index].agent?.model = ModelID(rawValue: model)
        return pipeline
    }

    private func task(_ id: TaskID, _ store: KabanStore) throws -> DurableTask {
        try store.database.read { try KabanStore.task(id, db: $0) }
    }
}
