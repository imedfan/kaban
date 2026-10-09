import Foundation
import KabanProtocol
import KabanKit
@testable import KabanDaemonCore

guard CommandLine.arguments.count == 2 else { exit(2) }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard (root.path.hasPrefix("/tmp/kaban-fe17-") || root.path.hasPrefix("/private/tmp/kaban-fe17-")),
      !FileManager.default.fileExists(atPath: root.path) else { exit(2) }
let repo = root.appendingPathComponent("repo")
try FileManager.default.createDirectory(at: repo.appendingPathComponent(".kaban"), withIntermediateDirectories: true)
let yaml = """
# Private git acceptance 👋
version: 1
git: {preset: standard}
board: {max_waiting_human: 16, max_runs_per_task: 20, bounce_limit_total: 8}
stages:
  - {id: backlog, kind: queue, on_success: dev}
  - id: dev
    kind: agent
    wip: 16
    agent: {model: explicit, skill: .kaban/dev.md, permissions: write}
    gates: ["/usr/bin/true"]
    retry: {max_attempts: 3, backoff: [30s]}
    on_success: review
  - {id: review, kind: human, wip: 16, on_success: merge}
  - {id: merge, kind: merge, wip: 1, on_success: done}
  - {id: done, kind: terminal}

"""
try yaml.write(to: repo.appendingPathComponent(".kaban/pipeline.yaml"), atomically: true, encoding: .utf8)
try "Private git acceptance".write(to: repo.appendingPathComponent(".kaban/dev.md"), atomically: true, encoding: .utf8)
func require(_ result: Bool, _ message: String) throws {
    if !result { throw NSError(domain: "GitPermissionsSeed", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
for args in [["init", "-b", "main"], ["config", "user.name", "Git QA"], ["config", "user.email", "git@example.test"], ["add", "."], ["commit", "-m", "Private git acceptance"]] {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", repo.path] + args
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit(); try require(process.terminationStatus == 0, "git \(args)")
}
let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
try require(try store.execute(.init(command: .addProject(path: repo.path, createTemplate: false, identity: .init(name: "Git QA", email: "git@example.test")))).result == .ok, "add project")
guard let project = try store.getSnapshot().projects.first?.id else { exit(3) }
_ = try store.setSettings(.init(maxConcurrentRuns: 16, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: Date())
let server = try MCPBoardServer(store: store); defer { server.stop() }
var evidence: [[String: Any]] = []
for name in ["fresh", "policy", "created", "delivered", "consumed", "revoked", "expired", "hard", "unknown", "limit", "stale", "long"] {
    let id = TaskID(rawValue: "git-" + name)
    let title = name == "long" ? String(repeating: "Длинный заголовок и аргумент 👋 ", count: 9) : "Git permissions · " + name
    try require(try store.execute(.init(command: .createTask(projectId: project, title: title, body: "Private acceptance\n\n## Критерии приёмки\n- [ ] Exact git permission")), makeTaskID: { id }).result == .taskCreated(id), "create")
    for suffix in ["admit", "run"] { _ = try store.tick(tickId: UUID(), runId: .init(rawValue: id.rawValue + "-" + suffix), at: Date()) }
    _ = try store.prepareTaskClone(taskId: id, at: Date(), workspaceRoot: root.appendingPathComponent("workspaces").path)
    let token = try store.issueRunToken(taskId: id, at: Date())
    let argv = name == "hard" ? ["git", "push", "origin", "main"] : name == "unknown" ? ["git", "future-git-command", "--future"] : ["git", "rebase", name == "long" ? String(repeating: "feature-👋-", count: 60) : "feature"]
    let response = try server.postGit(token: token, argv: argv, cwd: repo.path)
    try require(response.status == 200 && response.json["allow"] as? Bool == false, "real /git/check denial")
    guard let denial = try store.getTaskDetail(id).gitDenials.last else { exit(4) }
    if ["created", "delivered", "consumed", "revoked", "expired"].contains(name) {
        _ = try store.execute(.init(command: .allowGitOnce(denialId: denial.denial.denialId)))
        guard let grant = try store.getTaskDetail(id).gitGrants.last else { exit(5) }
        if name == "delivered" || name == "consumed" {
            _ = try server.roundTrip(token: token, method: "tools/call", params: ["name": "get_task_context", "arguments": [:]])
        }
        if name == "consumed" { try require(try server.postGit(token: token, argv: argv, cwd: repo.path).json["allow"] as? Bool == true, "consume through /git/check") }
        if name == "revoked" { _ = try store.execute(.init(command: .revokeGitGrant(grantId: grant.grant.grantId))) }
    }
    if name == "expired" || name == "stale" { _ = try store.execute(.init(command: .cancelTask(taskId: id, keepBranch: true))) }
    if name == "limit" {
        for number in 2...5 { _ = try server.postGit(token: token, argv: ["git", "rebase", "denied-\(number)"], cwd: repo.path) }
        try require(try store.getTaskDetail(id).task.state == .waitingHuman(.gitDenials), "five denials")
    }
    evidence.append(["task": id.rawValue, "producer": "loopback /git/check", "argv": argv, "denial": denial.denial.denialId.rawValue])
}
_ = try store.execute(.init(command: .pauseAll))
_ = try store.execute(.init(command: .createTask(projectId: project, title: "Git permissions · empty", body: "No git checks yet")), makeTaskID: { "git-empty" })
try JSONSerialization.data(withJSONObject: ["database": root.appendingPathComponent("store.sqlite").path, "producer": "MCPBoardServer /git/check, public production store APIs, no Cursor CLI", "denials": evidence], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("seed.json"))
print(root.path)
