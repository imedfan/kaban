import Foundation
import XCTest
import KabanProtocol
import KabanBoardCore
@testable import KabanDaemonCore

extension PipelineLifecycleTests {
    func testExactPipelineReadIsFreshUnjournaledAndSeparatesCommittedWorkingAndAbsent() throws {
        let f = try fixture(content: yaml)
        let read = CommandEnvelope(command: .getPipelineSource(projectId: f.project))
        let seq = try f.store.getSnapshot().seq
        guard case .pipelineSource(let first) = try f.store.execute(read).result else { return XCTFail("Exact source missing") }
        XCTAssertEqual(first.committedContent, yaml); XCTAssertEqual(first.workingContent, yaml)
        XCTAssertFalse(first.hasWorkingChanges)
        XCTAssertEqual(first.baseVersionHash, try summary(f).versionHash)
        XCTAssertEqual(first.baseSourceHash, try summary(f).sourceHash)
        let changed = "# exact 👋\r\n" + yaml + "# later\n"
        try self.changed(f, ".kaban/pipeline.yaml", changed)
        guard case .pipelineSource(let second) = try f.store.execute(read).result else { return XCTFail() }
        XCTAssertEqual(second.workingContent, changed); XCTAssertEqual(second.committedContent, yaml)
        XCTAssertTrue(second.hasWorkingChanges); XCTAssertEqual(second.baseSourceHash, first.baseSourceHash)
        XCTAssertNil(try f.store.execute(read).seq); XCTAssertEqual(try f.store.getSnapshot().seq, seq)
        try FileManager.default.removeItem(at: f.repo.appendingPathComponent(".kaban/pipeline.yaml"))
        guard case .pipelineSource(let missing) = try f.store.execute(read).result else { return XCTFail() }
        XCTAssertNil(missing.workingContent); XCTAssertEqual(missing.committedContent, yaml)
        let empty = try fixture()
        guard case .pipelineSource(let absent) = try empty.store.execute(.init(command: .getPipelineSource(projectId: empty.project))).result else { return XCTFail() }
        XCTAssertNil(absent.baseVersionHash); XCTAssertNil(absent.committedContent); XCTAssertNil(absent.workingContent)
    }
    func testNativeExactWrittenDraftRefusesRaceAndAppliesOneAuthoritativeVersion() throws {
        let f = try fixture(content: yaml)
        let read = CommandEnvelope(command: .getPipelineSource(projectId: f.project))
        guard case .pipelineSource(let source) = try f.store.execute(read).result else { return XCTFail() }
        let text = yaml.replacingOccurrences(of: "wip: 3", with: "wip: 1") + "# keep exact  👋\n"
        var draft = PipelineDraft(projectId: f.project, baseVersionHash: source.baseVersionHash, content: text, baseSourceHash: source.baseSourceHash)
        draft.requiresExactWorkingContent = true
        let command = CommandEnvelope(command: .updatePipeline(projectId: f.project, contentHash: draft.contentHash, draft: draft))
        let before = try git(f.repo, ["rev-parse", "HEAD"])
        XCTAssertEqual(try refusal(f.store.execute(command)).code, "pipeline_worktree_conflict")
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), before)
        try PipelineFileWriter.write(text, source: source)
        try changed(f, ".kaban/pipeline.yaml", "# external\n" + yaml)
        let raced = CommandEnvelope(command: command.command)
        XCTAssertEqual(try refusal(f.store.execute(raced)).code, "pipeline_worktree_conflict")
        XCTAssertEqual(try String(contentsOf: f.repo.appendingPathComponent(".kaban/pipeline.yaml"), encoding: .utf8), "# external\n" + yaml)
        try changed(f, ".kaban/pipeline.yaml", text)
        let accepted = CommandEnvelope(command: command.command)
        let reply = try f.store.execute(accepted)
        let version = try XCTUnwrap(summary(f).versionHash)
        XCTAssertEqual(reply.result, .pipelineVersion(hash: version))
        let after = try git(f.repo, ["rev-parse", "HEAD"])
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(try f.store.execute(accepted), reply)
        XCTAssertEqual(try git(f.repo, ["rev-parse", "HEAD"]), after)
        guard case .pipelineSource(let applied) = try f.store.execute(read).result else { return XCTFail() }
        XCTAssertEqual(applied.committedContent, text); XCTAssertEqual(applied.workingContent, text)
        XCTAssertEqual(applied.baseVersionHash, try summary(f).versionHash)
        XCTAssertEqual(try summary(f).stages.first { $0.id == "dev" }?.wip, 1)
        XCTAssertTrue(try f.store.events(after: 0).contains { event in
            if case .pipelineApplied(let pipeline) = event.event { return event.commandId == accepted.commandId && pipeline.versionHash == applied.baseVersionHash }
            return false
        })
    }
}
