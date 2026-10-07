import Foundation
import KabanProtocol
import KabanDaemonCore
import KabanKit

// Opt-in isolated acceptance fixture. Never opens the user's project/database,
// installs a helper or starts Cursor. Uses public store APIs, then clears journal.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--discard-journal" {
    let path = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
    guard path.hasPrefix("/tmp/kaban-fe10-") || path.hasPrefix("/private/tmp/kaban-fe10-") else { exit(2) }
    try KabanStore(path: path).discardJournal(); exit(0)
}
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: HumanAnswersSeed <new temporary directory>\n".utf8)); exit(2)
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
suspicious_files: {patterns: [".env*"], max_file_mb: 5}
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
func git(_ arguments: [String], path: String? = nil) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", path ?? repo.path] + arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "HumanAnswersSeed", code: 1) }
}
try git(["init", "-b", "main"])
try git(["config", "user.name", "Detail Acceptance"])
try git(["config", "user.email", "detail@example.test"])
try git(["add", "."]); try git(["commit", "-m", "Private acceptance pipeline"])
let path = root.appendingPathComponent("store.sqlite").path
let store = try KabanStore(path: path)
guard try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result == .ok,
      let project = try store.getSnapshot().projects.first?.id else { throw NSError(domain: "HumanAnswersSeed", code: 2) }
_ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: Date())
let body = "# Durable details\r\n\r\n**Exact body**  \r\n" + TaskMarkdown.acceptanceCriteriaSeparator + "- [ ] Keep source\n"
func prepare(_ id: TaskID) throws -> RunID {
    guard try store.execute(.init(command: .createTask(projectId: project, title: "Durable " + id.rawValue, body: body)), makeTaskID: { id }).result == .taskCreated(id) else { throw NSError(domain: "HumanAnswersSeed", code: 3) }
    _ = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-admit"), at: Date())
    let started = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-run"), at: Date())
    guard let run = started.transitions.last?.task.machine.currentRunId else {
        FileHandle.standardError.write(Data(("Could not reserve run for " + id.rawValue + "\n").utf8))
        throw NSError(domain: "HumanAnswersSeed", code: 4)
    }
    return run
}

let firstRun = try prepare("answer-question")
_ = try store.apply(.requestHuman(firstRun, question: "Check the current refund status first?"), taskId: "answer-question", commandId: UUID(), at: Date())
let questionID = try store.getTaskDetail("answer-question").humanRequests.last!.requestId
let staleRun = try prepare("answer-stale")
_ = try store.apply(.requestHuman(staleRun, question: "Old question"), taskId: "answer-stale", commandId: UUID(), at: Date())
let oldQuestionID = try store.getTaskDetail("answer-stale").humanRequests.last!.requestId
_ = try store.execute(.init(command: .answerHuman(taskId: "answer-stale", text: "Answered elsewhere.", requestId: oldQuestionID)))
let nextRun: RunID = "answer-stale-next-run"
_ = try store.tick(tickId: UUID(), runId: nextRun, at: Date())
_ = try store.apply(.requestHuman(nextRun, question: "New question"), taskId: "answer-stale", commandId: UUID(), at: Date())
let filesRun = try prepare("answer-files")
let workspace = root.appendingPathComponent("workspaces").path
let clone = try store.prepareTaskClone(taskId: "answer-files", at: Date(), workspaceRoot: workspace)
try "Acceptance fixture only\n".write(toFile: clone.clonePath + "/.env.local", atomically: true, encoding: .utf8)
try git(["add", ".env.local"], path: clone.clonePath)
try git(["commit", "-m", "Private suspicious result"], path: clone.clonePath)
_ = try store.apply(.completeStage(filesRun, summary: "A result with suspicious files."), taskId: "answer-files", commandId: UUID(), at: Date())
_ = try store.runProcessPass(owner: "isolated-frontend-acceptance", at: Date(), workspaceRoot: workspace, runner: nil)
for _ in 0..<8 { _ = try store.runStagePass(owner: "isolated-frontend-acceptance", at: Date()) }
_ = try store.execute(.init(command: .pauseAll))
guard try store.getTaskDetail("answer-stale").humanRequests.last!.requestId != oldQuestionID,
      try store.getTaskDetail("answer-files").task.state == .waitingHuman(.suspiciousFiles) else { throw NSError(domain: "HumanAnswersSeed", code: 8) }
try store.discardJournal()
let main = try TaskClone.mainCommit(repo.path, identity: nil)
let metadata = ["database": path, "question": "answer-question", "request": questionID.rawValue,
                "stale": "answer-stale", "oldRequest": oldQuestionID.rawValue, "files": "answer-files", "origin": repo.path, "main": main]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("fixture.json"))
print(root.appendingPathComponent("fixture.json").path)
