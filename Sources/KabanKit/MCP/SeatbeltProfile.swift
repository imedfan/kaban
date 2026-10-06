import Foundation

/// Write confinement for a tool process. Reads stay broad. This is not a guarantee that the Cursor CLI token is isolated.
public enum SeatbeltProfile {
    public static let tool = """
    (version 1)
    (deny default)
    (allow process-exec)
    (allow process-fork)
    (allow file-map-executable)
    (allow sysctl-read)
    (allow file-read*)
    (allow file-write*
      (require-all
        (subpath (param "CLONE"))
        (require-not (subpath (string-append (param "CLONE") "/.git")))
        (require-not (subpath (string-append (param "CLONE") "/.kaban"))))
      (subpath (param "SCRATCH"))
      (literal "/dev/null"))
    (deny file-write*
      (subpath (string-append (param "CLONE") "/.git"))
      (subpath (string-append (param "CLONE") "/.kaban")))
    (deny file-read*
      (subpath (string-append (param "FAKE_HOME") "/.ssh"))
      (subpath (string-append (param "FAKE_HOME") "/Library/Application Support/Cursor/User/globalStorage")))
    (allow network-outbound
      (remote ip (string-append "localhost:" (param "MCP_PORT")))
      (remote ip (string-append "localhost:" (param "PROXY_PORT"))))
    """

    public static func arguments(profile: String, clone: String, scratch: String, fakeHome: String, mcpPort: String, proxyPort: String, command: [String]) -> [String] {
        ["-f", profile, "-D", "CLONE=\(clone)", "-D", "SCRATCH=\(scratch)", "-D", "FAKE_HOME=\(fakeHome)", "-D", "MCP_PORT=\(mcpPort)", "-D", "PROXY_PORT=\(proxyPort)"] + command
    }
}
