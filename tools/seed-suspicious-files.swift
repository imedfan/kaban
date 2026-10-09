import Foundation
import KabanProtocol
import KabanKit
import KabanDaemonCore

guard CommandLine.arguments.count == 2 else { exit(2) }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard (root.path.hasPrefix("/tmp/kaban-fe18-") || root.path.hasPrefix("/private/tmp/kaban-fe18-")), !FileManager.default.fileExists(atPath: root.path) else { exit(2) }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func require(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "FilesSeed", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func git(_ path: URL, _ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", path.path] + arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit(); try require(process.terminationStatus == 0, "git \(arguments)")
}
let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
_ = try store.setSettings(.init(maxConcurrentRuns: 16, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: Date())
var evidence: [[String: Any]] = []
for mode in ["accept", "stale", "gate-empty", "gate-comment", "merge-empty", "merge-comment", "history", "long", "missing", "binary", "strict"] {
    let repo = root.appendingPathComponent(mode)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
    let yaml = """
    # Preserve suspicious file policy 👋
    version: 1
    git: {preset: \(mode == "strict" ? "strict" : "standard")}
    suspicious_files: {max_file_mb: 0.01}
    board: {max_waiting_human: 16, max_runs_per_task: 20, bounce_limit_total: 5}
    stages:
      - {id: backlog, kind: queue, on_success: dev}
      - id: dev
        kind: agent
        wip: 16
        agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
        gates: ["/usr/bin/true"]
        retry: {max_attempts: 3, backoff: [30s]}
        on_success: checks
      - {id: checks, kind: gate, wip: 16, gates: ["/usr/bin/true"], on_fail: {stage: dev, limit: 3}, on_success: review}
      - {id: review, kind: human, wip: 16, on_success: merge}
      - {id: merge, kind: merge, wip: 1, on_conflict: {stage: dev, limit: 2}, on_success: done}
      - {id: done, kind: terminal}

    """
    try yaml.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
    try "Private files acceptance".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
    for args in [["init", "-b", "main"], ["config", "user.name", "Files QA"], ["config", "user.email", "files@example.test"], ["add", "."], ["commit", "-m", "Private file acceptance"]] { try git(repo, args) }
    try require(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false, identity: .init(name: "Files QA", email: "files@example.test")))).result == .ok, "project")
    guard let project = try store.getSnapshot().projects.first(where: { $0.path == repo.path })?.id else { exit(3) }
    let id = TaskID(rawValue: "files-" + mode)
    _ = try store.execute(.init(command: .createTask(projectId: project, title: mode == "long" ? String(repeating: "Подозрительные файлы 👋 ", count: 9) : "Files · " + mode, body: "Private acceptance\n\n## Критерии приёмки\n- [ ] Exact file acceptance")), makeTaskID: { id })
    try require(try store.execute(.init(command: .moveTask(taskId: id, stage: "dev"))).result == .ok, "admit exact task")
    _ = try store.apply(.start(.init(rawValue: id.rawValue + "-run")), taskId: id, commandId: UUID(), at: Date())
    let descriptor = try store.prepareTaskClone(taskId: id, at: Date(), workspaceRoot: root.appendingPathComponent("workspaces").path)
    let clone = URL(fileURLWithPath: descriptor.clonePath)
    try git(clone, ["config", "user.name", "Files QA"]); try git(clone, ["config", "user.email", "files@example.test"])
    func transition(_ command: DurableTaskCommand) throws { _ = try store.apply(command, taskId: id, commandId: UUID(), at: Date()) }
    func stagePass() throws { _ = try store.runStagePass(owner: "private-qa", at: Date()) }
    func runID() throws -> RunID {
        guard let run = try store.getTaskDetail(id).runs.last?.id else { throw NSError(domain: "FilesSeed", code: 2, userInfo: [NSLocalizedDescriptionKey: "No started run for \(id.rawValue)"]) }
        return run
    }
    if mode.hasPrefix("gate") || mode.hasPrefix("merge") {
        try transition(.completeStage(try runID(), summary: "clean dev")); try stagePass()
        try require(try store.getTaskDetail(id).task.stageId == "checks", "clean dev -> checks")
        if mode.hasPrefix("merge") {
            try transition(.start(.init(rawValue: id.rawValue + "-checks"))); try stagePass()
            try transition(.start(.init(rawValue: id.rawValue + "-review")))
            try require(try store.execute(.init(command: .approve(taskId: id))).result == .ok, "review -> merge")
        }
    }
    let filePath = mode == "long" ? "nested/" + String(repeating: "очень-длинный-путь-👋-", count: 7) + "/.env" : ".env.local"
    try FileManager.default.createDirectory(at: clone.appendingPathComponent(filePath).deletingLastPathComponent(), withIntermediateDirectories: true)
    try "PRIVATE_QA=original\n".write(to: clone.appendingPathComponent(filePath), atomically: true, encoding: .utf8)
    try git(clone, ["add", filePath]); try git(clone, ["commit", "-m", "Private suspicious file"])
    if mode == "binary" {
        try Data(repeating: 0, count: 20_000).write(to: clone.appendingPathComponent("large.bin"))
        try git(clone, ["add", "large.bin"]); try git(clone, ["commit", "-m", "Private binary file"])
    }
    if mode.hasPrefix("gate") { try transition(.start(.init(rawValue: id.rawValue + "-checks"))) }
    else if mode.hasPrefix("merge") { try transition(.start(.init(rawValue: id.rawValue + "-merge"))) }
    else { try transition(.completeStage(try runID(), summary: "result")) }
    if mode.hasPrefix("merge") { _ = try store.runMergePass(owner: "private-qa", at: Date(), workspaceRoot: root.appendingPathComponent("workspaces").path) }
    else { try stagePass() }
    let shown = try store.getTaskDetail(id)
    try require(shown.task.state == .waitingHuman(.suspiciousFiles), "\(mode) not waiting: \(shown.task.state)")
    try require(!shown.suspiciousFiles.isEmpty, "no live scan")
    if mode == "stale" {
        try "PRIVATE_QA=changed\n".write(to: clone.appendingPathComponent(filePath), atomically: true, encoding: .utf8)
        try git(clone, ["add", filePath]); try git(clone, ["commit", "-m", "Changed while shown"])
    }
    if mode == "history" {
        _ = try store.execute(.init(command: .acceptSuspiciousFiles(taskId: id, files: shown.suspiciousFiles.map { .init(path: $0.path, blob: $0.blob) })))
        try stagePass()
    }
    if mode == "missing" { try FileManager.default.removeItem(at: clone) }
    evidence.append(["task": id.rawValue, "producer": "production branch-diff result check", "stage": shown.task.stageId.rawValue, "runs": shown.runs.count, "clone": clone.path])
}
_ = try store.execute(.init(command: .pauseAll))
try JSONSerialization.data(withJSONObject: ["producer": "real Git branch commits and production result checks; no Cursor CLI", "tasks": evidence], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("seed.json"))
print(root.path)
