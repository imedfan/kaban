import XCTest
import KabanDaemonCore
import KabanKit
import KabanProtocol

final class IncidentTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testBranchDiffFindsPatternsSizeAndStrictUncommittedFiles() throws {
        XCTAssertEqual(DaemonService.capabilities.commands.first { $0.name == "acceptSuspiciousFiles" }?.support, .supported)
        XCTAssertEqual(DaemonService.capabilities.commands.first { $0.name == "listIncidents" }?.support, .supported)
        let standard = try fixture(pipeline(preset: "standard", maxFileMB: "0.0001"))
        let clone = try reach(standard, "scan")
        try FileManager.default.createDirectory(at: clone.appendingPathComponent("api"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try "TOKEN=1\n".write(to: clone.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "LOCAL=1\n".write(to: clone.appendingPathComponent("api/.env.local"), atomically: true, encoding: .utf8)
        try "EXAMPLE=1\n".write(to: clone.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
        try "swapped\n".write(to: clone.appendingPathComponent(".cursor/mcp.json"), atomically: true, encoding: .utf8)
        var binary = Data(repeating: 0x61, count: 200)
        binary.append(0)
        try binary.write(to: clone.appendingPathComponent("big.bin"))
        try git(clone, ["add", ".env", "api/.env.local", ".env.example", ".cursor/mcp.json", "big.bin"])
        try git(clone, ["commit", "-m", "secrets"])
        try "note".write(to: clone.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try "SIDE=1\n".write(to: clone.appendingPathComponent(".env.side"), atomically: true, encoding: .utf8)
        let attempts = try task(standard, "scan").machine.attemptsUsed
        _ = try apply(standard, "scan", .completeStage(try runId(standard, "scan"), summary: "Dev done"))
        _ = try standard.store.runStagePass(owner: "test", at: at)
        let waiting = try task(standard, "scan")
        XCTAssertEqual(waiting.machine.state, .waitingHuman(.suspiciousFiles))
        XCTAssertEqual(waiting.machine.attemptsUsed, attempts)
        XCTAssertEqual(waiting.card.suspiciousFiles.map(\.path), [".env", "api/.env.local", "big.bin"])
        let detail = try standard.store.getTaskDetail("scan")
        XCTAssertEqual(detail.suspiciousFiles.map(\.path), waiting.card.suspiciousFiles.map(\.path))
        XCTAssertEqual(detail.suspiciousFiles.first { $0.path == ".env" }?.rule, .pattern)
        XCTAssertEqual(detail.suspiciousFiles.first { $0.path == ".env" }?.isText, true)
        XCTAssertEqual(detail.suspiciousFiles.first { $0.path == "api/.env.local" }?.pattern, ".env*")
        XCTAssertEqual(detail.suspiciousFiles.first { $0.path == "big.bin" }?.rule, .size)
        XCTAssertEqual(detail.suspiciousFiles.first { $0.path == "big.bin" }?.isText, false)
        XCTAssertTrue(detail.acceptedFiles.isEmpty)
        XCTAssertFalse(detail.suspiciousFiles.contains { $0.path == ".env.example" || $0.path == ".env.side" || $0.path == ".cursor/mcp.json" || $0.path == "note.txt" })
        try standard.store.discardJournal()
        let retained = try KabanStore(path: standard.path)
        let keptDetail = try retained.getTaskDetail("scan")
        XCTAssertEqual(keptDetail.suspiciousFiles.map(\.path), [".env", "api/.env.local", "big.bin"])
        let keptCard = try XCTUnwrap(retained.getSnapshot().tasks.first { $0.id == "scan" })
        XCTAssertEqual(keptCard.state, .waitingHuman(.suspiciousFiles))
        XCTAssertEqual(keptCard.suspiciousFiles.map(\.path), keptDetail.suspiciousFiles.map(\.path))

        let strict = try fixture(pipeline(preset: "strict"))
        let strictClone = try reach(strict, "strict")
        try "SIDE=1\n".write(to: strictClone.appendingPathComponent(".env.side"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: strictClone.appendingPathComponent(".env.link"), withDestinationURL: strictClone.appendingPathComponent(".env.side"))
        try "form".write(to: strictClone.appendingPathComponent("form.txt"), atomically: true, encoding: .utf8)
        _ = try apply(strict, "strict", .completeStage(try runId(strict, "strict"), summary: "strict"))
        _ = try strict.store.runStagePass(owner: "test", at: at)
        let found = try strict.store.getTaskDetail("strict").suspiciousFiles
        XCTAssertEqual(found.map(\.path), [".env.link", ".env.side"])
        XCTAssertEqual(try task(strict, "strict").machine.attemptsUsed, 0)
        XCTAssertFalse(found.contains { $0.path == "form.txt" })
    }

    func testBranchDiffPreservesUnicodeTabsNewlinesAndRenamedBinaryPaths() throws {
        let f = try fixture(pipeline(preset: "strict"))
        try Data([0, 1, 2, 0]).write(to: f.repo.appendingPathComponent("old.key"))
        try git(f.repo, ["add", "old.key"]); try git(f.repo, ["commit", "-m", "binary base"])
        let clone = try reach(f, "paths")
        let textPath = "вложенный 👋/.env\tс переводом\nстроки"
        let binaryPath = "ключ 👋\tновый.key"
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(textPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try "PRIVATE=fixture\n".write(to: clone.appendingPathComponent(textPath), atomically: true, encoding: .utf8)
        try git(clone, ["add", "--", textPath]); try git(clone, ["commit", "-m", "paths"])
        try git(clone, ["mv", "--", "old.key", binaryPath]); try git(clone, ["commit", "-m", "rename"])
        let untrackedPath = " \t/.env 👋\n"
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(untrackedPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try "UNTRACKED=fixture\n".write(to: clone.appendingPathComponent(untrackedPath), atomically: true, encoding: .utf8)
        _ = try apply(f, "paths", .completeStage(try runId(f, "paths"), summary: "path result"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        let found = try f.store.getTaskDetail("paths").suspiciousFiles
        XCTAssertEqual(Set(found.map(\.path)), Set([textPath, binaryPath, untrackedPath]))
        XCTAssertEqual(found.first(where: { $0.path == textPath })?.isText, true)
        XCTAssertEqual(found.first(where: { $0.path == binaryPath })?.isText, false)
        XCTAssertEqual(found.first(where: { $0.path == binaryPath })?.sizeBytes, 4)
    }

    func testAcceptanceRechecksLiveDiffBeforeRecordingTheShownSet() throws {
        for mode in ["changed", "added", "removed", "strict"] {
            let f = try fixture(pipeline(preset: mode == "strict" ? "strict" : "standard", maxFileMB: "1"))
            let clone = try reach(f, "stale")
            try "TOKEN=old\n".write(to: clone.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            try git(clone, ["add", ".env"])
            try git(clone, ["commit", "-m", "original"])
            _ = try apply(f, "stale", .completeStage(try runId(f, "stale"), summary: "done"))
            _ = try f.store.runStagePass(owner: "test", at: at)
            let before = try f.store.getTaskDetail("stale")
            XCTAssertEqual(before.task.state, .waitingHuman(.suspiciousFiles))
            XCTAssertEqual(before.fileCheck?.includesUncommitted, mode == "strict")
            XCTAssertEqual(before.fileCheck?.maxFileBytes, 1_048_576)
            XCTAssertNotNil(before.fileCheck?.baseCommit)
            XCTAssertEqual(before.fileCheck?.returnPipeline?.projectId, before.task.projectId)
            XCTAssertEqual(before.fileCheck?.returnPipeline?.stages.first(where: { $0.id == "dev" })?.onSuccess, "test")
            let shown = before.suspiciousFiles.map { FileBlobRef(path: $0.path, blob: $0.blob) }
            if mode == "removed" {
                try git(clone, ["rm", ".env"])
            } else {
                let path = mode == "added" ? ".env.new" : ".env"
                try "TOKEN=new\n".write(to: clone.appendingPathComponent(path), atomically: true, encoding: .utf8)
                if mode != "strict" { try git(clone, ["add", path]) }
            }
            if mode != "strict" { try git(clone, ["commit", "-m", "changed while shown"]) }
            let envelope = CommandEnvelope(command: .acceptSuspiciousFiles(taskId: "stale", files: shown))
            let reply = try f.store.execute(envelope, now: { self.at })
            XCTAssertEqual(code(reply), CommandError.staleSuspiciousFilesCode, mode)
            let refreshed = try f.store.getTaskDetail("stale")
            XCTAssertTrue(refreshed.acceptedFiles.isEmpty, mode)
            XCTAssertEqual(refreshed.task.state, .waitingHuman(.suspiciousFiles), mode)
            XCTAssertEqual(refreshed.runs.count, before.runs.count, mode)
            XCTAssertNotEqual(refreshed.suspiciousFiles.map(\.blob), before.suspiciousFiles.map(\.blob), mode)
            guard code(reply) == CommandError.staleSuspiciousFilesCode else { continue }
            XCTAssertEqual(try f.store.execute(envelope, now: { XCTFail("Replay read clock"); return self.at }), reply)
            let current = refreshed.suspiciousFiles.map { FileBlobRef(path: $0.path, blob: $0.blob) }
            XCTAssertEqual(try f.store.execute(.init(command: .acceptSuspiciousFiles(taskId: "stale", files: current)), now: { self.at }).result, .ok)
            _ = try f.store.runStagePass(owner: "test", at: at)
            XCTAssertEqual(try f.store.getTaskDetail("stale").runs.count, before.runs.count)
        }
    }

    func testAcceptExactSetContinuesWithoutANewRunAndAChangedBlobFiresAgain() throws {
        let f = try fixture(pipeline(preset: "standard"))
        let clone = try reach(f, "keep")
        try "TOKEN=1\n".write(to: clone.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent("api"), withIntermediateDirectories: true)
        try "LOCAL=1\n".write(to: clone.appendingPathComponent("api/.env.local"), atomically: true, encoding: .utf8)
        try git(clone, ["add", ".env", "api/.env.local"])
        try git(clone, ["commit", "-m", "secrets"])
        _ = try apply(f, "keep", .completeStage(try runId(f, "keep"), summary: "Dev done"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        let shown = try f.store.getTaskDetail("keep").suspiciousFiles
        let runsBefore = try f.store.getTaskDetail("keep").runs.count
        let stale = try f.store.execute(.init(command: .acceptSuspiciousFiles(taskId: "keep", files: [FileBlobRef(path: ".env", blob: "stale")])), now: { self.at })
        XCTAssertEqual(code(stale), CommandError.staleSuspiciousFilesCode)
        XCTAssertTrue(try f.store.getTaskDetail("keep").acceptedFiles.isEmpty)
        XCTAssertEqual(try task(f, "keep").machine.state, .waitingHuman(.suspiciousFiles))
        let exact = shown.map { FileBlobRef(path: $0.path, blob: $0.blob) }
        XCTAssertEqual(try f.store.execute(.init(command: .acceptSuspiciousFiles(taskId: "keep", files: exact.reversed())), now: { self.at }).result, .ok)
        _ = try f.store.runStagePass(owner: "test", at: at)
        let continued = try task(f, "keep")
        XCTAssertEqual(continued.machine.stageId.rawValue, "test")
        XCTAssertEqual(continued.machine.state.status, .queued)
        XCTAssertNil(continued.machine.currentRunId)
        XCTAssertEqual(try f.store.getTaskDetail("keep").runs.count, runsBefore)
        XCTAssertEqual(Set(try f.store.getTaskDetail("keep").acceptedFiles.map { FileBlobRef(path: $0.path, blob: $0.blob) }), Set(exact))
        _ = try apply(f, "keep", .start(RunID(rawValue: "keep-test")))
        _ = try apply(f, "keep", .completeStage(try runId(f, "keep"), summary: "test"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        XCTAssertEqual(try task(f, "keep").machine.stageId.rawValue, "review")
        XCTAssertNotEqual(try task(f, "keep").machine.state, .waitingHuman(.suspiciousFiles))
        _ = try apply(f, "keep", .start(RunID(rawValue: "keep-review")))
        XCTAssertEqual(try task(f, "keep").machine.state, .waitingHuman(.review))
        XCTAssertEqual(try f.store.execute(.init(command: .requestChanges(taskId: "keep", comments: "change the secret", target: "dev")), now: { self.at }).result, .ok)
        _ = try apply(f, "keep", .start(RunID(rawValue: "keep-again")))
        try "TOKEN=2\n".write(to: clone.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try git(clone, ["add", ".env"])
        try git(clone, ["commit", "-m", "rotate"])
        _ = try apply(f, "keep", .completeStage(try runId(f, "keep"), summary: "rotated"))
        _ = try f.store.runStagePass(owner: "test", at: at)
        let again = try f.store.getTaskDetail("keep").suspiciousFiles
        XCTAssertEqual(again.map(\.path), [".env"])
        XCTAssertNotEqual(again.first?.blob, shown.first { $0.path == ".env" }?.blob)
        XCTAssertFalse(again.contains { $0.path == "api/.env.local" })
    }

    func testLeavingCommandsFollowTheMachineAcceptSet() throws {
        let f = try fixture(pipeline(preset: "standard"))
        for id in ["ask", "changes", "retry", "move", "stop", "reject"] {
            let clone = try reach(f, TaskID(rawValue: id))
            try "TOKEN=1\n".write(to: clone.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            try git(clone, ["add", ".env"])
            try git(clone, ["commit", "-m", "secret"])
            _ = try apply(f, TaskID(rawValue: id), .completeStage(try runId(f, TaskID(rawValue: id)), summary: id))
            _ = try f.store.runStagePass(owner: "test", at: at)
            XCTAssertEqual(try task(f, TaskID(rawValue: id)).machine.state, .waitingHuman(.suspiciousFiles), id)
        }
        XCTAssertEqual(try f.store.execute(.init(command: .answerHuman(taskId: "ask", text: "remove the file", requestId: nil)), now: { self.at }).result, .ok)
        XCTAssertTrue(try f.store.getTaskDetail("ask").acceptedFiles.isEmpty)
        XCTAssertEqual(try task(f, "ask").machine.state.status, .queued)
        XCTAssertEqual(try f.store.execute(.init(command: .requestChanges(taskId: "changes", comments: "drop it", target: "dev")), now: { self.at }).result, .ok)
        XCTAssertTrue(try f.store.getTaskDetail("changes").acceptedFiles.isEmpty)
        XCTAssertEqual(try task(f, "changes").machine.stageId.rawValue, "dev")
        XCTAssertEqual(try f.store.execute(.init(command: .retryStage(taskId: "retry", grantAttempts: nil)), now: { self.at }).result, .ok)
        XCTAssertFalse(try f.store.getTaskDetail("retry").acceptedFiles.isEmpty)
        XCTAssertEqual(try task(f, "retry").machine.attemptsUsed, 0)
        XCTAssertEqual(try f.store.execute(.init(command: .moveTask(taskId: "move", stage: "backlog")), now: { self.at }).result, .ok)
        XCTAssertFalse(try f.store.getTaskDetail("move").acceptedFiles.isEmpty)
        XCTAssertEqual(try task(f, "move").machine.stageId.rawValue, "backlog")
        XCTAssertEqual(try f.store.execute(.init(command: .cancelTask(taskId: "stop", keepBranch: false)), now: { self.at }).result, .ok)
        XCTAssertFalse(try f.store.getTaskDetail("stop").acceptedFiles.isEmpty)
        XCTAssertEqual(try task(f, "stop").machine.state.status, .cancelled)
        XCTAssertEqual(try f.store.execute(.init(command: .reject(taskId: "reject", target: .stage(stageId: "dev"), keepBranch: true)), now: { self.at }).result, .ok)
        XCTAssertFalse(try f.store.getTaskDetail("reject").acceptedFiles.isEmpty)
        XCTAssertEqual(try task(f, "reject").machine.stageId.rawValue, "dev")
        try f.store.discardJournal()
        let reopened = try KabanStore(path: f.path)
        XCTAssertFalse(try reopened.getTaskDetail("retry").acceptedFiles.isEmpty)
        XCTAssertEqual(try reopened.getTaskDetail("ask").acceptedFiles.count, 0)
    }

    func testKabanChangesRollBackAndDoNotContinue() throws {
        let f = try fixture(pipeline(preset: "standard"))
        let untracked = try reach(f, "untracked")
        try "secret".write(to: untracked.appendingPathComponent(".kaban/extra"), atomically: true, encoding: .utf8)
        try expectIncident(f, "untracked", .kabanDirChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked.appendingPathComponent(".kaban/extra").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.appendingPathComponent(".kaban/pipeline.yaml").path))

        let tracked = try reach(f, "tracked")
        try "changed".write(to: tracked.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try git(tracked, ["add", ".kaban/dev.md"])
        try git(tracked, ["commit", "-m", "edit kaban"])
        try expectIncident(f, "tracked", .kabanDirChanged)
        XCTAssertEqual(try String(contentsOf: tracked.appendingPathComponent(".kaban/dev.md"), encoding: .utf8), "skill")

        let link = try reach(f, "link")
        try FileManager.default.removeItem(at: link.appendingPathComponent(".kaban"))
        try FileManager.default.createSymbolicLink(at: link.appendingPathComponent(".kaban"), withDestinationURL: link.appendingPathComponent("note.txt"))
        try expectIncident(f, "link", .kabanDirChanged)
        XCTAssertFalse(try URL(fileURLWithPath: link.appendingPathComponent(".kaban").path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.appendingPathComponent(".kaban/pipeline.yaml").path))
    }

    func testMainRepositoryDriftOpensADurableIncident() throws {
        let f = try fixture(pipeline(preset: "standard"))
        _ = try reach(f, "refs")
        try git(f.repo, ["branch", "sneak"])
        let opened = try expectIncident(f, "refs", .refsMoved)
        XCTAssertNotEqual(try gitStatus(f.repo, ["show-ref", "--verify", "--quiet", "refs/heads/sneak"]), 0)
        let snapshot = try f.store.getSnapshot()
        XCTAssertEqual(snapshot.openIncidentCount, snapshot.projects.map(\.openIncidentCount).reduce(0, +))
        XCTAssertEqual(snapshot.openIncidentCount, 1)
        let events = try f.store.events()
        let openCommand = events.last { if case .incidentOpened = $0.event { return true }; return false }?.commandId
        let same = events.filter { $0.commandId == openCommand }
        XCTAssertEqual(same.filter { if case .incidentOpened = $0.event { return true }; return false }.count, 1)
        XCTAssertEqual(same.filter { if case .projectUpdated(let project) = $0.event { return project.openIncidentCount == 1 }; return false }.count, 1)
        let listed = try f.store.execute(.init(command: .listIncidents(projectIds: [try XCTUnwrap(snapshot.projects.first?.id)], state: .open)))
        guard case .incidents(let rows) = listed.result else { return XCTFail("\(listed.result)") }
        XCTAssertEqual(rows.map(\.kind), [.refsMoved])
        XCTAssertEqual(rows.first?.id, opened)
        XCTAssertFalse(rows.first?.rolledBack.isEmpty ?? true)
        try f.store.discardJournal()
        let reopened = try KabanStore(path: f.path)
        let kept = try reopened.getSnapshot()
        XCTAssertEqual(kept.openIncidentCount, 1)
        XCTAssertEqual(kept.tasks.first { $0.id == "refs" }?.state, .waitingHuman(.incident))
        guard case .incidents(let durable) = try reopened.execute(.init(command: .listIncidents(projectIds: nil, state: .open))).result else { return XCTFail() }
        XCTAssertEqual(durable.map(\.id), [opened])
        let modelCommand = CommandEnvelope(command: .setModelOverride(taskId: "refs", stageId: "dev", model: nil))
        XCTAssertEqual(try reopened.execute(modelCommand).result, .ok)
        XCTAssertEqual(try reopened.getTaskDetail("refs").task.state, .waitingHuman(.incident))
        XCTAssertEqual(try reopened.getSnapshot().openIncidentCount, 1)
        XCTAssertFalse(try reopened.events().contains { if case .incidentResolved = $0.event { return true }; return false })
        let cancel = try reopened.execute(.init(command: .cancelTask(taskId: "refs", keepBranch: true)), now: { self.at })
        XCTAssertEqual(cancel.result, .ok)
        let resolved = try reopened.events().filter { $0.commandId == cancel.commandId }
        XCTAssertEqual(resolved.filter { if case .incidentResolved = $0.event { return true }; return false }.count, 1)
        XCTAssertEqual(resolved.filter { if case .projectUpdated(let project) = $0.event { return project.openIncidentCount == 0 }; return false }.count, 1)
        XCTAssertEqual(try reopened.getSnapshot().openIncidentCount, 0)
        guard case .incidents(let all) = try reopened.execute(.init(command: .listIncidents(projectIds: nil, state: .all))).result else { return XCTFail() }
        XCTAssertEqual(all.first?.resolvedAt != nil, true)
        XCTAssertEqual(all.first?.resolution, .init(command: "cancelTask", keepBranch: true, commandId: cancel.commandId))
        let frozenDetail = try reopened.getTaskDetail("refs")
        let frozen = frozenDetail.incidentPipeline
        XCTAssertEqual(frozenDetail.fileCheck?.returnPipeline, frozen)
        XCTAssertEqual(frozen?.projectId, snapshot.projects.first?.id)
        XCTAssertEqual(frozen?.defaultReturnStage, "dev")
        try reopened.discardJournal()
        let afterRetention = try KabanStore(path: f.path)
        guard case .incidents(let history) = try afterRetention.execute(.init(command: .listIncidents(projectIds: nil, state: .all))).result else { return XCTFail() }
        XCTAssertEqual(history.first?.resolution, all.first?.resolution)
        guard case .incidents(let open) = try reopened.execute(.init(command: .listIncidents(projectIds: nil, state: .open))).result else { return XCTFail() }
        XCTAssertTrue(open.isEmpty)

        _ = try reach(f, "tag")
        try git(f.repo, ["tag", "leaked"])
        _ = try expectIncident(f, "tag", .tagsChanged)
        XCTAssertNotEqual(try gitStatus(f.repo, ["show-ref", "--verify", "--quiet", "refs/tags/leaked"]), 0)

        _ = try reach(f, "config")
        let config = f.repo.appendingPathComponent(".git/config")
        try (String(contentsOf: config, encoding: .utf8) + "\n# kaban-drift\n").write(to: config, atomically: true, encoding: .utf8)
        _ = try expectIncident(f, "config", .configChanged)
        XCTAssertFalse(try String(contentsOf: config, encoding: .utf8).contains("kaban-drift"))

        let foreign = try reach(f, "foreign")
        let tree = try gitText(foreign, ["rev-parse", "HEAD^{tree}"])
        let commit = try gitText(foreign, ["commit-tree", tree, "-m", "foreign"])
        try git(foreign, ["reset", "--hard", commit])
        _ = try expectIncident(f, "foreign", .foreignBase)
        XCTAssertEqual(try gitText(foreign, ["rev-parse", "HEAD"]), try gitText(f.repo, ["rev-parse", "HEAD"]))
        let projectId = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        XCTAssertGreaterThan(try f.store.getSnapshot().openIncidentCount, 0)
        XCTAssertEqual(try f.store.execute(.init(command: .removeProject(projectId: projectId)), now: { self.at }).result, .ok)
        let gone = try f.store.getSnapshot()
        XCTAssertEqual(gone.openIncidentCount, gone.projects.map(\.openIncidentCount).reduce(0, +))
        XCTAssertEqual(gone.openIncidentCount, 0)
        XCTAssertTrue(gone.projects.isEmpty)
    }

    func testDaemonLaunchesTwice() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanDaemon")
        let executable = ProcessInfo.processInfo.environment["KABAN_DAEMON"].map { URL(fileURLWithPath: $0) } ?? binary
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build KabanDaemon before the incident launch") }
        let f = try fixture(pipeline(preset: "strict"))
        let clone = try reach(f, "once")
        try "TOKEN=1\n".write(to: clone.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        _ = try apply(f, "once", .completeStage(try runId(f, "once"), summary: "Dev done"))
        let first = try runDaemon(executable, database: f.path)
        let second = try runDaemon(executable, database: f.path)
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertEqual(first.stderr, second.stderr)
        XCTAssertTrue(first.stderr.contains("stage once result dev suspicious"))
        XCTAssertEqual(try task(f, "once").machine.state, .waitingHuman(.suspiciousFiles))
        if let root = ProcessInfo.processInfo.environment["KABAN_PROCESS_EVIDENCE"].map(URL.init(fileURLWithPath:)) {
            try first.stderr.write(to: root.appendingPathComponent("be-13-launch-1.log"), atomically: true, encoding: .utf8)
            try second.stderr.write(to: root.appendingPathComponent("be-13-launch-2.log"), atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    private func expectIncident(_ f: Fixture, _ id: TaskID, _ kind: IncidentKind) throws -> IncidentID {
        let attempts = try task(f, id).machine.attemptsUsed
        let runs = try f.store.getTaskDetail(id).runs.count
        _ = try apply(f, id, .completeStage(try runId(f, id), summary: id.rawValue))
        _ = try f.store.runStagePass(owner: "test", at: at)
        let waiting = try task(f, id)
        XCTAssertEqual(waiting.machine.state, .waitingHuman(.incident), id.rawValue)
        XCTAssertEqual(waiting.machine.openIncident, kind, id.rawValue)
        XCTAssertEqual(waiting.machine.attemptsUsed, attempts, id.rawValue)
        _ = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-later"), at: at)
        let held = try task(f, id)
        XCTAssertEqual(held.machine.state, .waitingHuman(.incident), id.rawValue)
        XCTAssertNil(held.machine.currentRunId)
        XCTAssertEqual(try f.store.getTaskDetail(id).runs.count, runs)
        let listed = try f.store.execute(.init(command: .listIncidents(projectIds: nil, state: .open)))
        guard case .incidents(let rows) = listed.result else {
            XCTFail("\(listed.result)")
            return IncidentID(rawValue: "")
        }
        return try XCTUnwrap(rows.last { $0.taskId == id && $0.kind == kind }?.id)
    }

    private func code(_ reply: CommandReply) -> String? {
        if case .error(let error) = reply.result { return error.code }
        return nil
    }

    private struct Fixture { let root: URL; let repo: URL; let workspace: String; let path: String; var store: KabanStore }

    private func pipeline(preset: String, maxFileMB: String? = nil) -> String {
        let suspicious = maxFileMB.map { "\nsuspicious_files: {max_file_mb: \($0)}" } ?? ""
        return """
        version: 1
        board: {max_waiting_human: 8, bounce_limit_total: 5, max_runs_per_task: 12}
        git: {preset: \(preset)}\(suspicious)
        stages:
          - {id: backlog, kind: queue, on_success: dev}
          - id: dev
            kind: agent
            wip: 8
            agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
            gates: ["/usr/bin/true"]
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: test
          - id: test
            kind: agent
            wip: 8
            agent: {model: explicit, skill: .kaban/dev.md}
            gates: ["/usr/bin/true"]
            retry: {max_attempts: 3, backoff: [30s]}
            on_success: review
          - {id: review, kind: human, wip: 8, on_success: merge}
          - {id: merge, kind: merge, wip: 1, on_success: done}
          - {id: done, kind: terminal}
        """
    }

    private func fixture(_ yaml: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-incident-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try yaml.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
        try "skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
        try "board\n".write(to: repo.appendingPathComponent(".cursor/mcp.json"), atomically: true, encoding: .utf8)
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["config", "user.name", "Incident Test"])
        try git(repo, ["config", "user.email", "incident@example.test"])
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "Pipeline"])
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        XCTAssertEqual(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result, .ok)
        _ = try store.setSettings(.init(maxConcurrentRuns: 8, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: at)
        return Fixture(root: root, repo: repo, workspace: root.appendingPathComponent("workspaces").path, path: path, store: store)
    }

    private func reach(_ f: Fixture, _ id: TaskID) throws -> URL {
        let project = try XCTUnwrap(f.store.getSnapshot().projects.first?.id)
        let reply = try f.store.execute(.init(command: .createTask(projectId: project, title: id.rawValue, body: "Task\n\n## Критерии приёмки\n- [ ] Ready")), now: { self.at }, makeTaskID: { id })
        XCTAssertEqual(reply.result, .taskCreated(id))
        _ = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-admit"), at: at)
        let started = try f.store.tick(tickId: UUID(), runId: RunID(rawValue: id.rawValue + "-run"), at: at)
        XCTAssertEqual(started.transitions.last?.task.machine.state, .running)
        let clone = try f.store.prepareTaskClone(taskId: id, at: at, workspaceRoot: f.workspace)
        let url = URL(fileURLWithPath: clone.clonePath)
        // clone does not copy the origin's local identity, and the daemon git environment ignores the global config.
        try git(url, ["config", "user.name", "Incident Test"])
        try git(url, ["config", "user.email", "incident@example.test"])
        return url
    }

    private func task(_ f: Fixture, _ id: TaskID) throws -> DurableTask {
        try XCTUnwrap(f.store.snapshot().tasks.first { $0.card.id == id })
    }

    private func runId(_ f: Fixture, _ id: TaskID) throws -> RunID {
        try XCTUnwrap(task(f, id).machine.lastRunId)
    }

    private func apply(_ f: Fixture, _ id: TaskID, _ command: DurableTaskCommand) throws -> DurableReceipt {
        try f.store.apply(command, taskId: id, commandId: UUID(), at: at)
    }

    private func git(_ repo: URL, _ args: [String]) throws {
        let status = try gitStatus(repo, args)
        XCTAssertEqual(status, 0, "\(args)")
    }

    private func gitText(_ repo: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.environment = DaemonGit.processEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(args)")
        var text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    private func gitStatus(_ repo: URL, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.environment = DaemonGit.processEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private struct DaemonOutput { var status: Int32; var stderr: String }
    private func runDaemon(_ binary: URL, database: String) throws -> DaemonOutput {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--stage-pass", "--stdio", "--database", database]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return DaemonOutput(status: process.terminationStatus, stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
