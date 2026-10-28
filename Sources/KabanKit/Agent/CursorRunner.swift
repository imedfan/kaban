import Foundation
import KabanProtocol

public struct CursorRunnerAssessment: Equatable, Sendable {
    public var version: String?
    public var reason: RunnerUnavailableReason?
    public var limitsNote: String?
    public var authOK: Bool
    public var catalog: [ModelInfo]?
    public init(version: String?, reason: RunnerUnavailableReason?, limitsNote: String?, authOK: Bool = false, catalog: [ModelInfo]? = nil) {
        self.version = version
        self.reason = reason
        self.limitsNote = limitsNote
        self.authOK = authOK
        self.catalog = catalog
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
            if version.code != 0 || versionLine(version.text) == nil {
                return CursorRunnerAssessment(version: nil, reason: .agentNotRunnable, limitsNote: nil)
            }
            let status = invoke(path, ["status", "--format", "json"], environment)
            let models = invoke(path, ["--list-models"], environment)
            let statusText = status.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let auth = (try? JSONSerialization.jsonObject(with: Data(status.stdout.utf8))) as? [String: Any]
            let explicitAuth = auth?["isAuthenticated"] as? Bool
            let confirmed = status.code == 0 && (explicitAuth == true || statusText.split(separator: "\n").contains { line in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return value == "ready" || value == "logged in" || value.hasPrefix("logged in as ") ||
                    value == "signed in" || value.hasPrefix("signed in as ") || value == "authenticated successfully"
            })
            let reason = loginFailure(in: status.text) ?? (explicitAuth == false ? .agentNotLoggedIn : (confirmed ? nil : .agentNotRunnable))
            return CursorRunnerAssessment(version: versionLine(version.text), reason: reason,
                limitsNote: limitsNote(from: models.text), authOK: reason == nil && confirmed,
                catalog: models.code == 0 ? ModelCatalogMatcher.parseListModels(models.text) : nil)
        }
    }

    /// `--list-models` only. It does not start a model prompt. A missing executable returns nil.
    public static func listModelsText(executable path: String?, environment: [String: String]) -> String? {
        guard let path, !path.isEmpty, executableState(path) == .runnable else { return nil }
        let models = invoke(path, ["--list-models"], environment)
        return models.code == 0 ? models.text : nil
    }

    public static let mcpListTimeout: TimeInterval = 20

    /// `mcp list` in the run's working directory and environment. It does not start a model prompt.
    /// A missing executable, a timeout, or a crash returns a nil code, which the preflight reads as unreadable.
    public static func listMCP(executable path: String?, environment: [String: String], workingDirectory: String) -> (text: String, code: Int32?) {
        guard let path, !path.isEmpty, executableState(path) == .runnable else { return ("", nil) }
        let result = invoke(path, ["mcp", "list"], environment, workingDirectory: workingDirectory, timeout: mcpListTimeout)
        return (result.stdout, result.code)
    }

    public static func environmentReport(executable: String?, environment: [String: String], notificationsAuthorized: Bool) -> EnvironmentReport {
        let runner = assess(executable: executable, environment: environment)
        let git = invoke("/usr/bin/git", ["--version"], environment)
        #if os(macOS)
        let sandbox = invoke("/usr/bin/sandbox-exec", ["-p", "(version 1) (allow default)", "/usr/bin/true"], environment).code == 0
        #else
        let sandbox = false
        #endif
        return .init(cursorAgentPath: executable, version: runner.version, authOK: runner.authOK,
                     gitVersion: git.code == 0 ? versionLine(git.text) : nil,
                     sandboxOK: sandbox, notificationsAuthorized: notificationsAuthorized)
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

    struct Invocation {
        var stdout: String
        var stderr: String
        var code: Int32?
        var text: String { stdout + stderr }
    }

    static func invoke(_ executable: String, _ arguments: [String], _ environment: [String: String], workingDirectory: String? = nil, timeout: TimeInterval = 2) -> Invocation {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-cursor-probe-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("out").path
            let error = directory.appendingPathComponent("err").path
            _ = FileManager.default.createFile(atPath: output, contents: Data(), attributes: [.posixPermissions: 0o600])
            _ = FileManager.default.createFile(atPath: error, contents: Data(), attributes: [.posixPermissions: 0o600])
            let handle = try ProcessGroup.spawn(executable: executable, arguments: arguments, workingDirectory: workingDirectory ?? directory.path, environment: environment, standardOutput: output, standardError: error)
            let deadline = Date().addingTimeInterval(timeout)
            var code = ProcessGroup.poll(handle.pid)
            while code == nil && Date() < deadline {
                let size = [output, error].reduce(UInt64(0)) { size, path in
                    size + (((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0)
                }
                if size > 65_536 { break }
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
            func text(_ path: String) -> String {
                guard let file = FileHandle(forReadingAtPath: path) else { return "" }
                defer { try? file.close() }
                return String(data: (try? file.read(upToCount: 65_536)) ?? Data(), encoding: .utf8) ?? ""
            }
            let bytes = [output, error].reduce(UInt64(0)) { size, path in
                size + (((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0)
            }
            return Invocation(stdout: text(output), stderr: text(error), code: bytes > 65_536 ? nil : code)
        } catch {
            return Invocation(stdout: "", stderr: "", code: nil)
        }
    }
}
