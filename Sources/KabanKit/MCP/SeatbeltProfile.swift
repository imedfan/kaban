import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The CLI and every descendant share this boundary. It does not isolate the CLI's login token.
public enum SeatbeltProfile {
    public static let executable = "/usr/bin/sandbox-exec"

    // External IP traffic is permitted (host allowlisting is outside MVP). Loopback has one exception.
    // Keep the profile in argv, outside every agent-writable directory.
    public static let tool = """
    (version 1)
    (deny default)
    (allow process-exec process-fork file-map-executable sysctl-read)
    (allow signal (target same-sandbox))
    (allow file-read*)
    (allow file-write*
      (subpath (param "CLONE"))
      (subpath (param "SCRATCH"))
      (subpath (param "CLI_RUNNING"))
      (literal "/dev/null")
      (literal (string-append (param "RUN_HOME") "/.cursor/agent-cli-state.json"))
      (literal (string-append (param "RUN_HOME") "/.cursor/cli-config.json"))
      (literal (string-append (param "RUN_HOME") "/.cursor/statsig-cache.json"))
      (subpath (string-append (param "RUN_HOME") "/.cursor/chats"))
      (subpath (string-append (param "RUN_HOME") "/.cursor/projects"))
      (subpath (string-append (param "RUN_HOME") "/.cursor/ai-tracking"))
      (subpath (string-append (param "RUN_HOME") "/.cursor/managed"))
      (subpath (string-append (param "RUN_HOME") "/.cursor/plugins/cache"))
      (subpath (string-append (param "RUN_HOME") "/.cursor/skills-cursor"))
      (subpath (string-append (param "RUN_HOME") "/Library/Caches/cursor-compile-cache"))
      (subpath (string-append (param "RUN_HOME") "/.local/bin"))
      (subpath (string-append (param "RUN_HOME") "/.local/share/cursor-agent/versions")))
    (deny file-write*
      (literal (string-append (param "REAL_HOME") "/.gitconfig"))
      (subpath (string-append (param "CLONE") "/.git/config"))
      (subpath (string-append (param "CLONE") "/.git/hooks"))
      (subpath (string-append (param "CLONE") "/.git/info"))
      (subpath (string-append (param "CLONE") "/.kaban")))
    ; Do not allow replacing the protected git directory as a whole.
    (deny file-write-unlink (literal (string-append (param "CLONE") "/.git")))
    (deny file-read*
      (subpath (string-append (param "REAL_HOME") "/.ssh"))
      (subpath (string-append (param "REAL_HOME") "/Library/Application Support/Cursor/User/globalStorage")))
    (allow mach-lookup
      (global-name "com.apple.SecurityServer")
      (global-name "com.apple.securityd")
      (global-name "com.apple.trustd.agent")
      (global-name "com.apple.system.opendirectoryd.libinfo")
      (global-name "com.apple.system.notification_center")
      (global-name "com.apple.cfprefsd.agent")
      (global-name "com.apple.cfprefsd.daemon"))
    (allow system-socket (socket-domain AF_INET) (socket-domain AF_INET6) (socket-domain AF_UNIX))
    ; Cursor's observed worker socket stays inside its run-local service directories.
    (allow network-bind network-inbound network-outbound
      (subpath (param "SCRATCH"))
      (subpath (string-append (param "RUN_HOME") "/.cursor/projects")))
    (allow network-outbound (literal "/private/var/run/mDNSResponder"))
    (allow network-outbound
      (require-all (remote ip "*:*") (require-not (remote ip "localhost:*"))))
    """

    /// Precreate only the observed BE-22 service directories; never grant the entire HOME or host temp.
    public static func prepareRunDirectories(home: URL) throws -> URL {
        for path in [".cursor/chats", ".cursor/projects", ".cursor/ai-tracking", ".cursor/managed",
                     ".cursor/plugins/cache", ".cursor/skills-cursor", "Library/Caches/cursor-compile-cache",
                     ".local/bin", ".local/share/cursor-agent/versions", "tmp"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        return home.appendingPathComponent("tmp")
    }

    public static func arguments(clone: String, scratch: String, runHome: String, realHome: String,
                                 repository: String?, cli: String, mcpPort: UInt16?, command: [String]) -> [String] {
        // Foundation may abbreviate /private/var to /var; Seatbelt matches the kernel's physical path.
        func physical(_ path: String) -> String {
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                return String(cString: resolved)
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path != "/" else { return "/" }
            return URL(fileURLWithPath: physical(url.deletingLastPathComponent().path)).appendingPathComponent(url.lastPathComponent).path
        }
        let running = URL(fileURLWithPath: physical(cli)).deletingLastPathComponent().appendingPathComponent(".running").path
        var parameters = [("CLONE", physical(clone)), ("SCRATCH", physical(scratch)), ("RUN_HOME", physical(runHome)),
                          ("REAL_HOME", physical(realHome)),
                          ("CLI_RUNNING", running)]
        var profile = tool
        if let mcpPort, mcpPort > 0 {
            parameters.append(("MCP_PORT", String(mcpPort)))
            profile += "\n(allow network-outbound (remote ip (string-append \"localhost:\" (param \"MCP_PORT\"))))"
        }
        if let repository {
            parameters.append(("REPOSITORY", physical(repository)))
            profile += "\n(deny file-write* (subpath (param \"REPOSITORY\")))"
        }
        return ["-p", profile] + parameters.flatMap { ["-D", "\($0.0)=\($0.1)"] } + command
    }
}
