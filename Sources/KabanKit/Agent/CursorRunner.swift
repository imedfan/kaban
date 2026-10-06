import Foundation
import KabanProtocol

public struct CursorRunnerAssessment: Equatable, Sendable {
    public var version: String?
    public var reason: RunnerUnavailableReason?
    public var limitsNote: String?
    public init(version: String?, reason: RunnerUnavailableReason?, limitsNote: String?) {
        self.version = version
        self.reason = reason
        self.limitsNote = limitsNote
    }
}

public enum CursorRunner {
    public static let recheckInterval: TimeInterval = 300

    public enum ExecutableState: Equatable, Sendable {
        case missing
        case notExecutable
        case runnable
    }

    public static func executableState(_ path: String) -> ExecutableState {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return .missing }
        return FileManager.default.isExecutableFile(atPath: path) ? .runnable : .notExecutable
    }

    /// A failed status is not a login failure unless the text says so. Missing output is not zero usage and not a guessed session.
    public static func loginFailure(in statusText: String) -> RunnerUnavailableReason? {
        let text = statusText.lowercased()
        let loggedOut = ["not logged in", "not authenticated", "unauthenticated", "please log in", "please login",
                         "login required", "logged out", "no credentials", "not signed in", "sign in required"]
        if loggedOut.contains(where: { text.contains($0) }) { return .agentNotLoggedIn }
        let auth = ["invalid api key", "invalid api-key", "authentication failed", "unauthorized"]
        if auth.contains(where: { text.contains($0) }) { return .runnerAuth }
        return nil
    }

    /// Runs `--version`, `status`, and `--list-models` only. It does not start a model prompt.
    public static func assess(executable path: String?, environment: [String: String]) -> CursorRunnerAssessment {
        guard let path, !path.isEmpty else { return CursorRunnerAssessment(version: nil, reason: .agentMissing, limitsNote: nil) }
        switch executableState(path) {
        case .missing:
            return CursorRunnerAssessment(version: nil, reason: .agentMissing, limitsNote: nil)
        case .notExecutable:
            return CursorRunnerAssessment(version: nil, reason: .agentNotRunnable, limitsNote: nil)
        case .runnable:
            let version = invoke(path, ["--version"], environment)
            let status = invoke(path, ["status"], environment)
            let models = invoke(path, ["--list-models"], environment)
            if !version.spawned && !status.spawned {
                return CursorRunnerAssessment(version: nil, reason: .agentNotRunnable, limitsNote: nil)
            }
            return CursorRunnerAssessment(version: versionLine(version.text), reason: loginFailure(in: status.text), limitsNote: limitsNote(from: models.text))
        }
    }

    /// `--list-models` only. It does not start a model prompt. A missing executable returns nil.
    public static func listModelsText(executable path: String?, environment: [String: String]) -> String? {
        guard let path, !path.isEmpty, executableState(path) == .runnable else { return nil }
        let models = invoke(path, ["--list-models"], environment)
        return models.spawned ? models.text : nil
    }

    public static func versionLine(_ text: String) -> String? {
        guard let line = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) else { return nil }
        let value = String(line.prefix(120))
        let lower = value.lowercased()
        if value.contains("@") || lower.contains("key") || lower.contains("token") || lower.contains("secret") { return nil }
        return value
    }

    public static func limitsNote(from text: String) -> String? {
        let lines = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { line in
            !line.isEmpty && !line.contains("@") && line.count < 200 && !line.lowercased().contains("token") && !line.lowercased().contains("secret")
        }
        let joined = lines.prefix(20).joined(separator: "\n")
        return joined.isEmpty ? nil : String(joined.prefix(500))
    }

    private struct Invocation {
        var text: String
        var spawned: Bool
    }

    private static func invoke(_ executable: String, _ arguments: [String], _ environment: [String: String]) -> Invocation {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-cursor-probe-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("out").path
            let error = directory.appendingPathComponent("err").path
            _ = FileManager.default.createFile(atPath: output, contents: Data())
            _ = FileManager.default.createFile(atPath: error, contents: Data())
            let handle = try ProcessGroup.spawn(executable: executable, arguments: arguments, workingDirectory: directory.path, environment: environment, standardOutput: output, standardError: error)
            let deadline = Date().addingTimeInterval(15)
            var code = ProcessGroup.poll(handle.pid)
            while code == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
                code = ProcessGroup.poll(handle.pid)
            }
            if code == nil {
                _ = try? ProcessGroup.stop(pid: handle.pid, processGroup: handle.processGroup, birth: handle.birth)
                let reap = Date().addingTimeInterval(1)
                while code == nil && Date() < reap {
                    Thread.sleep(forTimeInterval: 0.02)
                    code = ProcessGroup.poll(handle.pid)
                }
            }
            let stdout = (try? String(contentsOfFile: output, encoding: .utf8)) ?? ""
            let stderr = (try? String(contentsOfFile: error, encoding: .utf8)) ?? ""
            return Invocation(text: stdout + stderr, spawned: true)
        } catch {
            return Invocation(text: "", spawned: false)
        }
    }
}
