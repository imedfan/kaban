import Foundation

/// One pipeline gate or hook. The command string is the stage text; it runs through `/bin/sh -c` in the clone.
/// Timeout kills the process group. Output is capped. The run token and secret-looking variables are not copied in.
public enum StageCommand {
    public struct Result: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public var timedOut: Bool
    }

    public static let outputLimit = 8_192

    public static func environment(stage: [String: String] = [:]) -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG"] {
            if let value = base[key] { env[key] = value }
        }
        for (key, value) in base where key.hasPrefix("LC_") { env[key] = value }
        for (key, value) in stage where !key.hasPrefix("GIT_") && !secret(key) { env[key] = value }
        return env
    }

    /// `timeout` is a deadline, not a sleep. A command that has already exited is reaped with `WNOHANG`.
    public static func run(command: String, cwd: String, environment: [String: String], timeout: TimeInterval, onStart: ((ProcessGroup.Handle) throws -> Void)? = nil) throws -> Result {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(status: 0, output: "", timedOut: false) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-stage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("out").path
        let stderr = directory.appendingPathComponent("err").path
        let gate = directory.appendingPathComponent("start").path
        let launcher = "i=0; while [ ! -f \"$1\" ]; do i=$((i+1)); [ \"$i\" -lt 100 ] || exit 125; /bin/sleep 0.05; done; shift; exec \"$@\""
        let arguments = onStart == nil ? ["-c", trimmed] : ["-c", launcher, "kaban-stage-launch", gate, "/bin/sh", "-c", trimmed]
        let handle = try ProcessGroup.spawn(executable: "/bin/sh", arguments: arguments, workingDirectory: cwd, environment: environment, standardOutput: stdout, standardError: stderr)
        if let onStart {
            do {
                try onStart(handle)
                try Data().write(to: URL(fileURLWithPath: gate), options: .atomic)
            } catch {
                _ = try? ProcessGroup.stop(pid: handle.pid, processGroup: handle.processGroup, birth: handle.birth)
                throw error
            }
        }
        let deadline = Date().addingTimeInterval(max(timeout, 0.05))
        var status = ProcessGroup.poll(handle.pid)
        var timedOut = false
        while status == nil {
            if Date() >= deadline {
                timedOut = true
                _ = try? ProcessGroup.stop(pid: handle.pid, processGroup: handle.processGroup, birth: handle.birth)
                let reap = Date().addingTimeInterval(1)
                while ProcessGroup.poll(handle.pid) == nil && Date() < reap {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                status = 124
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
            status = ProcessGroup.poll(handle.pid)
        }
        let output = cap(read(stdout) + read(stderr))
        return Result(status: status ?? 124, output: output, timedOut: timedOut)
    }

    private static func secret(_ key: String) -> Bool {
        let upper = key.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD"].contains { upper.contains($0) }
    }

    private static func read(_ path: String) -> String {
        guard let data = FileHandle(forReadingAtPath: path).map({ handle -> Data in
            defer { try? handle.close() }
            return handle.readData(ofLength: outputLimit + 1)
        }) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func cap(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > outputLimit else { return text }
        return String(decoding: bytes.prefix(outputLimit), as: UTF8.self) + "\n[truncated]"
    }
}
