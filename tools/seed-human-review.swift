import Foundation
import KabanProtocol
import KabanDaemonCore
import KabanKit

// Private acceptance data only: public production store APIs and real git/gates.
// Never registers a service, touches the user's repository or starts Cursor CLI.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--discard-journal" {
    let path = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
    guard path.hasPrefix("/tmp/kaban-fe11-") || path.hasPrefix("/private/tmp/kaban-fe11-") else { exit(2) }
    try KabanStore(path: path).discardJournal(); exit(0)
}
guard CommandLine.arguments.count == 2 else { exit(2) }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard (root.path.hasPrefix("/tmp/kaban-fe11-") || root.path.hasPrefix("/private/tmp/kaban-fe11-")),
      !FileManager.default.fileExists(atPath: root.path) else { exit(2) }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let repo = root.appendingPathComponent("repo")
try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
let pipeline = """
version: 1
board: {max_waiting_human: 8, max_runs_per_task: 12}
stages:
  - {id: backlog, kind: queue, on_success: dev}
  - id: dev
    kind: agent
    wip: 8
    agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
    gates: ["/usr/bin/printf 'Private review gate passed\\n'"]
    retry: {max_attempts: 3, backoff: [30s]}
    on_success: review
  - {id: review, kind: human, wip: 8, on_success: merge}
  - {id: merge, kind: merge, wip: 1, on_success: done}
  - {id: done, kind: terminal}

"""
try pipeline.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
try "Private acceptance skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
func git(_ arguments: [String], path: String? = nil) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", path ?? repo.path] + arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "HumanReviewSeed", code: 1) }
}
try git(["init", "-b", "main"])
try git(["config", "user.name", "Private Review Acceptance"])
try git(["config", "user.email", "review@example.test"])
try git(["add", "."]); try git(["commit", "-m", "Private review pipeline"])
let path = root.appendingPathComponent("store.sqlite").path
let workspace = root.appendingPathComponent("workspaces").path
let store = try KabanStore(path: path)
guard try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result == .ok,
      let project = try store.getSnapshot().projects.first?.id else { throw NSError(domain: "HumanReviewSeed", code: 2) }
_ = try store.setSettings(.init(maxConcurrentRuns: 8, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: Date())
let names = ["approve", "changes", "reject-stage", "reject-keep", "reject-delete", "stale"]
var metadata = ["database": path, "origin": repo.path, "main": try TaskClone.mainCommit(repo.path, identity: nil)]
for name in names {
    let id = TaskID(rawValue: "review-" + name)
    guard try store.execute(.init(command: .createTask(projectId: project, title: "Private review: " + name,
          body: "Review the actual committed result.\n" + TaskMarkdown.acceptanceCriteriaSeparator + "- [ ] Preserve source\n")),
          makeTaskID: { id }).result == .taskCreated(id) else { throw NSError(domain: "HumanReviewSeed", code: 3) }
    _ = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-admit"), at: Date())
    let started = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-run"), at: Date())
    guard let run = started.transitions.last?.task.machine.currentRunId else { throw NSError(domain: "HumanReviewSeed", code: 4) }
    let clone = try store.prepareTaskClone(taskId: id, at: Date(), workspaceRoot: workspace)
    try "Actual result for \(name)\nSecond line 👋\n".write(toFile: clone.clonePath + "/result.txt", atomically: true, encoding: .utf8)
    _ = try store.apply(.completeStage(run, summary: "Actual summary for " + name), taskId: id, commandId: UUID(), at: Date())
    _ = try store.runProcessPass(owner: "private-review-acceptance", at: Date(), workspaceRoot: workspace, runner: nil)
    for _ in 0..<8 { _ = try store.runStagePass(owner: "private-review-acceptance", at: Date()) }
    _ = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-review"), at: Date())
    let detail = try store.getTaskDetail(id)
    guard detail.task.state == .waitingHuman(.review), detail.clonePath == clone.clonePath,
          Set(detail.artifacts.map(\.kind)).isSuperset(of: ["summary", "diffstat", "commits", "gate_output"]) else {
        FileHandle.standardError.write(Data("Incomplete \(id): \(detail.task.state), \(detail.artifacts.map(\.kind))\n".utf8))
        throw NSError(domain: "HumanReviewSeed", code: 5)
    }
    metadata[name] = id.rawValue; metadata[name + "Clone"] = clone.clonePath
    metadata[name + "Commit"] = try TaskClone.head(clone.clonePath, identity: nil)
}
_ = try store.execute(.init(command: .pauseAll))
try store.discardJournal()
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("fixture.json"))
print(root.appendingPathComponent("fixture.json").path)
