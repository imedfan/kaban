import Foundation
import KabanProtocol
import KabanDaemonCore

guard CommandLine.arguments.count == 3 else { exit(2) }
let mode = CommandLine.arguments[1]
let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard root.path.hasPrefix("/tmp/kaban-fe20-") || root.path.hasPrefix("/private/tmp/kaban-fe20-") else { exit(2) }
if mode == "seed" {
    guard !FileManager.default.fileExists(atPath: root.path) else { exit(2) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    for args in [["init", "-b", "main"], ["config", "user.name", "Mac QA"], ["config", "user.email", "mac@example.test"], ["commit", "--allow-empty", "-m", "Private Mac QA"]] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { exit(3) }
    }
    let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
    _ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: Date())
    guard try store.execute(.init(command: .addProject(path: repo.path, createTemplate: true, identity: .init(name: "Mac QA", email: "mac@example.test")))).result == .ok else { exit(4) }
} else {
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("store.sqlite").path), ["fresh", "unknown", "stale", "flags"].contains(mode) else { exit(2) }
    let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path), now = Date()
    let quota = QuotaState(cm: mode == "unknown" ? nil : 46, om: mode == "unknown" ? nil : 93,
                           billingCycleStart: now.addingTimeInterval(-14 * 86400), billingCycleEnd: now.addingTimeInterval(17 * 86400),
                           fetchedAt: mode == "stale" ? now.addingTimeInterval(-1801) : now)
    var flags: [SchedulerFlag] = [], models: [ModelFlag] = []
    if mode == "flags" {
        flags = [.runnerUnavailable(.runnerAuth), .rateLimited(cooldownUntil: now.addingTimeInterval(3600), step: 1),
                 .usageExhaustedUnknown(resetsAt: nil), .poolUsageExhausted(.om, resetsAt: nil), .poolUsageExhausted(.cm, resetsAt: now.addingTimeInterval(86400))]
        models = [.init(modelId: "opus-qa", reason: .unavailable, requested: "Длинная модель для проверки недоступности Cursor", since: now),
                  .init(modelId: "gpt-qa", reason: .substituted, requested: "GPT QA", actual: "Composer QA", fallbackModel: "composer-qa", since: now)]
    }
    _ = try store.setSchedulerInputs(.init(flags: flags, modelFlags: models, quota: quota), commandId: UUID(), at: now)
}
