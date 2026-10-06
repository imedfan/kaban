import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A child in its own process group. Stop signals that group and does not wait for it.
public enum ProcessGroup {
    public struct ProcessBirth: Equatable, Sendable, Codable {
        public var seconds: Int64
        public var microseconds: Int32
        public init(seconds: Int64, microseconds: Int32) {
            self.seconds = seconds
            self.microseconds = microseconds
        }
    }

    public struct Handle: Equatable, Sendable {
        public var pid: Int32
        public var processGroup: Int32
        public var birth: ProcessBirth
    }

    public enum Stop: Equatable, Sendable {
        case signaled
        case alreadyGone
    }

    public enum Failure: Error, Equatable {
        case spawn(Int32)
        case foreignGroup
    }

    /// `nil` while the leader is still running. `WNOHANG` only: this does not wait for a timeout.
    public static func poll(_ pid: Int32) -> Int32? {
        guard pid > 1 else { return nil }
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == 0 { return nil }
            if result == pid {
                if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
                let signal = status & 0x7f
                if signal > 0 && signal < 0x7f { return 128 + signal }
                return nil
            }
            if errno != EINTR { return nil }
        }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public static func processGroup(of pid: Int32) -> Int32? {
        let group = getpgid(pid)
        return group > 1 ? group : nil
    }

    /// Signals `processGroup` only when `pid` is still that group's leader and still the process we spawned.
    @discardableResult
    public static func stop(pid: Int32, processGroup: Int32, birth: ProcessBirth) throws -> Stop {
        guard pid > 1, processGroup == pid else { throw Failure.foreignGroup }
        guard isAlive(pid) else { return .alreadyGone }
        guard getpgid(pid) == processGroup, self.birth(pid) == birth else { throw Failure.foreignGroup }
        let result = kill(-processGroup, SIGKILL)
        if result != 0 && errno != ESRCH { throw Failure.spawn(errno) }
        return result == 0 ? .signaled : .alreadyGone
    }

    /// A zombie cannot write to the clone; birth identity also excludes PID reuse.
    public static func isExecuting(_ pid: Int32, birth expected: ProcessBirth) -> Bool {
        guard birth(pid) == expected else { return false }
        #if os(macOS)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = name.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        return result == 0 && size >= MemoryLayout<kinfo_proc>.stride && info.kp_proc.p_stat != SZOMB
        #else
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let close = stat.lastIndex(of: ")") else { return false }
        return stat[stat.index(after: close)...].split(separator: " ").first != "Z"
        #endif
    }

    public static func spawn(executable: String, arguments: [String], workingDirectory: String, environment: [String: String], standardOutput: String, standardError: String) throws -> Handle {
        // Darwin imports these as nullable pointers. Glibc imports them as structs.
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #endif
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.spawn(errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attr) == 0 else { throw Failure.spawn(errno) }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)) == 0 else { throw Failure.spawn(errno) }
        guard posix_spawnattr_setpgroup(&attr, 0) == 0 else { throw Failure.spawn(errno) }

        let input = open("/dev/null", O_RDONLY)
        let output = open(standardOutput, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        let error = open(standardError, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        defer {
            if input >= 0 { close(input) }
            if output >= 0 { close(output) }
            if error >= 0 { close(error) }
        }
        guard input >= 0, output >= 0, error >= 0 else { throw Failure.spawn(errno) }
        guard posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, input) == 0,
              posix_spawn_file_actions_addclose(&actions, output) == 0,
              posix_spawn_file_actions_addclose(&actions, error) == 0 else { throw Failure.spawn(errno) }
        guard workingDirectory.withCString({ posix_spawn_file_actions_addchdir_np(&actions, $0) }) == 0 else { throw Failure.spawn(errno) }

        var pid: pid_t = 0
        let code = withCStrings([executable] + arguments) { argv in
            withCStrings(environment.map { "\($0.key)=\($0.value)" }.sorted()) { envp in
                executable.withCString { path in
                    posix_spawn(&pid, path, &actions, &attr, argv, envp)
                }
            }
        }
        guard code == 0, pid > 1 else { throw Failure.spawn(code == 0 ? EINVAL : code) }
        let group = getpgid(pid)
        guard group == pid, let birth = birth(pid) else {
            _ = kill(pid, SIGKILL)
            throw Failure.spawn(EINVAL)
        }
        return Handle(pid: pid, processGroup: group, birth: birth)
    }

    public static func birth(_ pid: Int32) -> ProcessBirth? {
        #if os(macOS)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = name.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, 4, &info, &size, nil, 0)
        }
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return ProcessBirth(seconds: Int64(info.kp_proc.p_starttime.tv_sec), microseconds: Int32(info.kp_proc.p_starttime.tv_usec))
        #else
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let ticks = Int64(fields[19]) else { return nil }
        return ProcessBirth(seconds: ticks, microseconds: 0)
        #endif
    }

    private static func withCStrings(_ values: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Int32) -> Int32 {
        let pointers = values.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = pointers
        argv.append(nil)
        return argv.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

public enum TechnicalExit: Equatable, Sendable {
    /// Exit 0 with activity and no final MCP call. The stage does not advance.
    case noFinalCall
    /// Exit 0 with no output and no file changes. BE-15 classifies this; it is not a stage result.
    case silentDeferred
    /// The run is no longer active. A late exit does not change the task.
    case inactive
    case crash(Int32)
}

public enum ProcessExitClassifier {
    public static func classify(exitCode: Int32, runStillActive: Bool, producedActivity: Bool, changedFiles: Bool) -> TechnicalExit {
        guard runStillActive else { return .inactive }
        guard exitCode == 0 else { return .crash(exitCode) }
        if !producedActivity && !changedFiles { return .silentDeferred }
        return .noFinalCall
    }
}

public struct ProcessDeadlines: Equatable, Sendable {
    public var stall: Date
    public var wall: Date
    public enum Kind: Equatable, Sendable { case stall, wall }
    public init(stall: Date, wall: Date) { self.stall = stall; self.wall = wall }
    /// Compares the clock the caller already has. It does not sleep.
    public func due(at now: Date) -> Kind? {
        if now >= wall { return .wall }
        if now >= stall { return .stall }
        return nil
    }
}
