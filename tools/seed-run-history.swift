import Foundation
import KabanProtocol
import KabanDaemonCore
import KabanKit

// Opt-in isolated acceptance fixture. Never opens the user's project/database,
// installs a helper or starts Cursor. Uses public store APIs, then clears journal.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: RunHistorySeed <new temporary directory>\n".utf8)); exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard (root.path.hasPrefix("/tmp/") || root.path.hasPrefix("/private/tmp/") || root.path.hasPrefix(NSTemporaryDirectory())),
      !FileManager.default.fileExists(atPath: root.path) else {
    FileHandle.standardError.write(Data("Fixture requires a new temporary directory.\n".utf8)); exit(2)
}
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let repo = root.appendingPathComponent("repo")
try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
let pipeline = """
version: 1
board: {max_waiting_human: 4, max_runs_per_task: 12}
stages:
  - {id: backlog, kind: queue, on_success: dev}
  - id: dev
    kind: agent
    wip: 4
    agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
    retry: {max_attempts: 3, backoff: [30s]}
    on_success: review
  - {id: review, kind: human, wip: 4, on_success: merge}
  - {id: merge, kind: merge, wip: 1, on_success: done}
  - {id: done, kind: terminal}

"""
try pipeline.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
try "Acceptance fixture only".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
func git(_ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repo.path] + arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "RunHistorySeed", code: 1) }
}
try git(["init", "-b", "main"])
try git(["config", "user.name", "Detail Acceptance"])
try git(["config", "user.email", "detail@example.test"])
try git(["add", "."]); try git(["commit", "-m", "Private acceptance pipeline"])
let path = root.appendingPathComponent("store.sqlite").path
let store = try KabanStore(path: path)
guard try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result == .ok,
      let project = try store.getSnapshot().projects.first?.id else { throw NSError(domain: "RunHistorySeed", code: 2) }
_ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: Date())
let body = "# Durable details\r\n\r\n**Exact body**  \r\n" + TaskMarkdown.acceptanceCriteriaSeparator + "- [ ] Keep source\n"
func prepare(_ id: TaskID) throws -> RunID {
    guard try store.execute(.init(command: .createTask(projectId: project, title: "Durable " + id.rawValue, body: body)), makeTaskID: { id }).result == .taskCreated(id) else { throw NSError(domain: "RunHistorySeed", code: 3) }
    _ = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-admit"), at: Date())
    let started = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-run"), at: Date())
    guard let run = started.transitions.last?.task.machine.currentRunId else {
        FileHandle.standardError.write(Data(("Could not reserve run for " + id.rawValue + "\n").utf8))
        throw NSError(domain: "RunHistorySeed", code: 4)
    }
    return run
}

let run = try prepare("log-wip")
let workspace = root.appendingPathComponent("workspaces").path
let clone = try store.prepareTaskClone(taskId: "log-wip", at: Date(), workspaceRoot: workspace)
try "selected snapshot".write(toFile: clone.clonePath + "/draft.txt", atomically: true, encoding: .utf8)
let secret = "sk-QaSecretValue123456789"
let lines = try (0..<1100).map { index in
    String(decoding: try JSONSerialization.data(withJSONObject: ["type": "assistant", "text": "Record \(index) " + secret]), as: UTF8.self) + "\n"
}.joined()
try store.ingestAgentOutput(runId: run, taskId: "log-wip", chunk: Data(lines.utf8), complete: true, directory: root.appendingPathComponent("logs").path)
_ = try store.apply(.runFailed(run, .crash), taskId: "log-wip", commandId: UUID(), at: Date())
_ = try store.runProcessPass(owner: "isolated-frontend-acceptance", at: Date(), workspaceRoot: workspace, runner: nil)
_ = try store.execute(.init(command: .pauseTask(taskId: "log-wip")))
_ = try store.execute(.init(command: .pauseAll))
let detail = try store.getTaskDetail("log-wip")
guard let summary = detail.runs.first, summary.id == run, let ref = summary.wipRef,
      !FileManager.default.fileExists(atPath: clone.clonePath + "/draft.txt") else { throw NSError(domain: "RunHistorySeed", code: 6) }
try "backup me".write(toFile: clone.clonePath + "/local.txt", atomically: true, encoding: .utf8)
let page = try store.readLog(runId: run, fromOffset: 76, limit: 100)
guard page.availableFromOffset == 76, page.endOffset == 1100,
      !String(decoding: try KabanCoding.makeEncoder().encode(page), as: UTF8.self).contains(secret) else { throw NSError(domain: "RunHistorySeed", code: 7) }
let main = try TaskClone.mainCommit(repo.path, identity: nil)
let head = try TaskClone.head(clone.clonePath, identity: nil)
try KabanCoding.makeEncoder().encode(detail.runs).write(to: root.appendingPathComponent("history.json"))
try store.discardJournal()
let metadata = ["database": path, "task": "log-wip", "run": run.rawValue, "wip": ref, "clone": clone.clonePath,
                "origin": repo.path, "main": main, "head": head, "secret": secret, "history": root.appendingPathComponent("history.json").path]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("fixture.json"))
print(root.appendingPathComponent("fixture.json").path)
