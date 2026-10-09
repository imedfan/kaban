import Foundation
import KabanProtocol
import KabanDaemonCore
import KabanKit

guard CommandLine.arguments.count >= 2 else { exit(2) }
let root = URL(fileURLWithPath: CommandLine.arguments.last!).standardizedFileURL
guard root.path.hasPrefix("/tmp/kaban-fe19-") || root.path.hasPrefix("/private/tmp/kaban-fe19-") else { exit(2) }
let path = root.appendingPathComponent("store.sqlite").path
if CommandLine.arguments.contains("--discard-journal") { try KabanStore(path: path).discardJournal(); exit(0) }
guard !FileManager.default.fileExists(atPath: root.path) else { exit(2) }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let store = try KabanStore(path: path)
let yaml = """
version: 1
board: {max_waiting_human: 8, bounce_limit_total: 5, max_runs_per_task: 12}
git: {preset: standard}
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
func git(_ repo: URL, _ arguments: [String]) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repo.path] + arguments
    let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "IncidentSeed", code: 1) }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func project(_ name: String) throws -> (URL, ProjectID) {
    let repo = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
    try yaml.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
    try "Private incident skill".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
    for args in [["init", "-b", "main"], ["config", "user.name", "Incident QA"], ["config", "user.email", "incident@example.test"], ["add", "."], ["commit", "-m", "Private incident pipeline"]] { _ = try git(repo, args) }
    guard try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false))).result == .ok,
          let id = try store.getSnapshot().projects.first(where: { $0.path == repo.path })?.id else { throw NSError(domain: "IncidentSeed", code: 2) }
    return (repo, id)
}
_ = try store.setSettings(.init(maxConcurrentRuns: 8, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: Date())
let (repo, projectID) = try project("repo")
let (removedRepo, removedID) = try project("removed-repo")
var metadata: [String: String] = ["database": path, "project": projectID.rawValue, "removedProject": removedID.rawValue]
for name in ["refs", "tags", "config", "kaban", "foreign", "unknown", "deleted"] {
    let id = TaskID(rawValue: "incident-" + name)
    let source = name == "deleted" ? removedRepo : repo
    let project = name == "deleted" ? removedID : projectID
    let title = name == "kaban" ? String(repeating: "Длинное название 👋 проверка защищённой конфигурации · ", count: 6) : "Нарушение · " + name
    guard try store.execute(.init(command: .createTask(projectId: project, title: title, body: "Разобрать инцидент\n" + TaskMarkdown.acceptanceCriteriaSeparator + "- [ ] Проверить refs")), makeTaskID: { id }).result == .taskCreated(id) else { throw NSError(domain: "IncidentSeed", code: 3) }
    _ = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-admit"), at: Date())
    let started = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-run"), at: Date())
    guard let run = started.transitions.last?.task.machine.currentRunId else { throw NSError(domain: "IncidentSeed", code: 4) }
    let clone = try store.prepareTaskClone(taskId: id, at: Date(), workspaceRoot: root.appendingPathComponent("workspaces").path)
    let cloneURL = URL(fileURLWithPath: clone.clonePath)
    _ = try git(cloneURL, ["config", "user.name", "Incident QA"]); _ = try git(cloneURL, ["config", "user.email", "incident@example.test"])
    switch name {
    case "refs", "deleted", "unknown": _ = try git(source, ["branch", "forbidden-" + name])
    case "tags": _ = try git(source, ["tag", "forbidden-tag"])
    case "config":
        let config = source.appendingPathComponent(".git/config")
        try (String(contentsOf: config, encoding: .utf8) + "\n# forbidden-qa\n").write(to: config, atomically: true, encoding: .utf8)
    case "kaban": try "Forbidden modification".write(to: cloneURL.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
    case "foreign":
        let tree = try git(cloneURL, ["rev-parse", "HEAD^{tree}"])
        let commit = try git(cloneURL, ["commit-tree", tree, "-m", "foreign"])
        _ = try git(cloneURL, ["reset", "--hard", commit])
    default: break
    }
    _ = try store.apply(.completeStage(run, summary: "Private incident result"), taskId: id, commandId: UUID(), at: Date())
    _ = try store.runStagePass(owner: "private-incident-qa", at: Date())
    let detail = try store.getTaskDetail(id)
    guard detail.task.state == .waitingHuman(.incident) else { throw NSError(domain: "IncidentSeed", code: 5, userInfo: [NSLocalizedDescriptionKey: "No incident: " + name]) }
    guard case .incidents(let records) = try store.execute(.init(command: .listIncidents(projectIds: nil, state: .all))).result,
          let incident = records.first(where: { $0.taskId == id }) else { throw NSError(domain: "IncidentSeed", code: 6) }
    if incident.rolledBack.isEmpty { throw NSError(domain: "IncidentSeed", code: 7) }
    metadata[name] = incident.id.rawValue
    metadata[name + "Task"] = id.rawValue
    if name == "refs" {
        guard try store.execute(.init(command: .setModelOverride(taskId: id, stageId: "dev", model: "qa-only-override"))).result == .ok else { throw NSError(domain: "IncidentSeed", code: 10) }
    }
    if name == "deleted" {
        guard try store.execute(.init(command: .cancelTask(taskId: id, keepBranch: true))).result == .ok,
              try store.execute(.init(command: .removeProject(projectId: project))).result == .ok else { throw NSError(domain: "IncidentSeed", code: 8) }
    }
}
guard try store.execute(.init(command: .pauseAll)).result == .ok else { throw NSError(domain: "IncidentSeed", code: 9) }
try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent("seed.json"))
print(root.path)
