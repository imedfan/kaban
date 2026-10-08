import Foundation
import KabanProtocol
import KabanKit
@testable import KabanDaemonCore

// Opt-in private acceptance only. Every git mutation is confined to a new temporary fixture.
// No system service registration or Cursor CLI invocation.
guard CommandLine.arguments.count == 3 else { exit(2) }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let mode = CommandLine.arguments[2]
guard (root.path.hasPrefix("/tmp/kaban-fe12-") || root.path.hasPrefix("/private/tmp/kaban-fe12-")),
      !FileManager.default.fileExists(atPath: root.path),
      ["queue", "dirty", "conflict", "review", "recovery", "gates"].contains(mode) else { exit(2) }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let repo = root.appendingPathComponent("repo")
try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
let pipeline = """
version: 1
board: {max_waiting_human: 8, max_runs_per_task: 12, bounce_limit_total: 6}
stages:
  - {id: backlog, kind: queue, on_success: dev}
  - id: dev
    kind: agent
    wip: 8
    agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
    gates: ["/usr/bin/true"]
    retry: {max_attempts: 3, backoff: [30s]}
    on_success: review
  - {id: review, kind: human, wip: 8, on_success: merge}
  - id: merge
    kind: merge
    wip: 1
    gates: \(mode == "gates" ? "[\"/usr/bin/false\"]" : "[]")
    on_conflict: {stage: dev, limit: 1}
    on_success: done
  - {id: done, kind: terminal}

"""
try pipeline.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
try "Private merge acceptance".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
try "base\n".write(to: repo.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "MergeSeed", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
@discardableResult func git(_ arguments: [String], path: String? = nil) throws -> String {
    let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", path ?? repo.path] + arguments
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    try require(process.terminationStatus == 0, "git failed: \(arguments)")
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
try git(["init", "-b", "main"]); try git(["config", "user.name", "Private Merge"]); try git(["config", "user.email", "merge@example.test"])
try git(["add", "."]); try git(["commit", "-m", "Private merge pipeline"])
let database = root.appendingPathComponent("store.sqlite").path, workspace = root.appendingPathComponent("workspaces").path
let store = try KabanStore(path: database)
try require(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result == .ok, "add project")
guard let project = try store.getSnapshot().projects.first?.id else { exit(3) }
_ = try store.setSettings(.init(maxConcurrentRuns: 8, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: Date())
func tick() throws { _ = try store.tick(tickId: UUID(), runId: .init(rawValue: UUID().uuidString.lowercased()), at: Date()) }
func apply(_ command: DurableTaskCommand, _ id: TaskID) throws { _ = try store.apply(command, taskId: id, commandId: UUID(), at: Date()) }
func finish(_ id: TaskID, summary: String) throws {
    guard let run = try store.snapshot().tasks.first(where: { $0.card.id == id })?.machine.currentRunId else { exit(4) }
    try apply(.completeStage(run, summary: summary), id)
    _ = try store.runProcessPass(owner: "private-merge", at: Date(), workspaceRoot: workspace, runner: nil)
    for _ in 0..<8 { _ = try store.runStagePass(owner: "private-merge", at: Date()) }
    try tick()
    try require(try store.getTaskDetail(id).task.state == .waitingHuman(.review), "Human Review required")
}
func create(_ id: TaskID, file: String) throws -> TaskCloneSnapshot {
    try require(try store.execute(.init(command: .createTask(projectId: project, title: "Private merge: \(id.rawValue)", body: "Actual result.\n" + TaskMarkdown.acceptanceCriteriaSeparator + "- [ ] Preserve local main\n")), makeTaskID: { id }).result == .taskCreated(id), "create task")
    try tick(); try tick()
    let clone = try store.prepareTaskClone(taskId: id, at: Date(), workspaceRoot: workspace)
    try "task result 👋\n".write(toFile: clone.clonePath + "/" + file, atomically: true, encoding: .utf8)
    try finish(id, summary: "Real committed result for \(id)")
    return clone
}
let first: TaskID = "merge-first", second: TaskID = "merge-second"
let file = ["dirty", "conflict", "review"].contains(mode) ? "shared.txt" : "first.txt"
let clone = try create(first, file: file)
if ["queue", "dirty"].contains(mode) { _ = try create(second, file: "second.txt") }
let base = try git(["rev-parse", "refs/heads/main"])
if ["conflict", "review"].contains(mode) {
    try "main diverged\n".write(to: repo.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    try git(["add", "shared.txt"]); try git(["commit", "-m", "Private main change"])
}
if mode == "dirty" {
    try "user staged\n".write(to: repo.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8); try git(["add", "shared.txt"])
    try "user unstaged\n👋\n".write(to: repo.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
}
if mode != "queue" {
    try apply(.approve, first)
    if mode == "dirty" { try apply(.approve, second) }
    try tick()
    if mode == "recovery" {
        for _ in 0..<8 {
            if try store.pendingEffectItems().contains(where: { if case .fastForwardMerge = $0.effect { return true }; return false }) { break }
            if try store.rebaseOneMerge(owner: "private-merge", at: Date(), workspaceRoot: workspace) { continue }
            _ = try store.runResultEffect(owner: "private-merge", at: Date())
        }
        guard let effect = try store.pendingEffectItems().first(where: { if case .fastForwardMerge = $0.effect { return true }; return false }),
              let lease = try store.claimEffect(id: effect.id, owner: "private-merge", at: Date()) else { exit(5) }
        try require(try store.prepareFastForward(lease: lease, at: Date()).outcome == .merged, "actual fast forward")
        // Smaller crash gap: main moved, SQLite has no external fact/receipt yet.
        try store.database.write { db in try db.execute(sql: "UPDATE effect SET external_fact = NULL WHERE id = ?", arguments: [effect.id]) }
    } else { _ = try store.runMergePass(owner: "private-merge", at: Date(), workspaceRoot: workspace) }
}
if mode == "conflict" || mode == "review" {
    try require(try store.getTaskDetail(first).task.stageId == "dev", "automatic conflict return")
    try tick()
    if mode == "review" {
        try git(["fetch", repo.path, "main"], path: clone.clonePath)
        try git(["reset", "--hard", "FETCH_HEAD"], path: clone.clonePath)
        try "resolved result 👋\n".write(toFile: clone.clonePath + "/shared.txt", atomically: true, encoding: .utf8)
    }
    try finish(first, summary: mode == "review" ? "Conflict fixed; Human Review again" : "Second result still conflicts")
    if mode == "conflict" { try apply(.approve, first); try tick(); _ = try store.runMergePass(owner: "private-merge", at: Date(), workspaceRoot: workspace) }
}
_ = try store.execute(.init(command: .pauseAll))
var metadata = ["database": database, "origin": repo.path, "workspace": workspace, "mode": mode, "project": project.rawValue, "first": first.rawValue,
                "second": second.rawValue, "base": base, "main": try git(["rev-parse", "refs/heads/main"]), "commits": try git(["rev-list", "--count", "main"])]
if mode == "dirty" {
    metadata["staged"] = try git(["diff", "--cached"]); metadata["unstaged"] = try git(["diff"])
    metadata["file"] = try String(contentsOf: repo.appendingPathComponent("shared.txt"), encoding: .utf8)
}
try store.discardJournal()
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("fixture.json"))
print(root.appendingPathComponent("fixture.json").path)
