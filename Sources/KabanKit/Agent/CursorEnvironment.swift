import Foundation
import KabanProtocol
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// The persisted allowlist contains paths only. Credentials remain in the host process.
public struct ResolvedCursorEnvironment: Codable, Equatable, Sendable {
    public var configuration: CursorEnvironment
    public var searchPath: String
    public var toolchains: [String: String]

    public init(configuration: CursorEnvironment, searchPath: String, toolchains: [String: String]) {
        self.configuration = configuration; self.searchPath = searchPath; self.toolchains = toolchains
    }

    public func processEnvironment(inheriting environment: [String: String]) -> [String: String] {
        var result = environment
        result["PATH"] = searchPath
        for key in CursorEnvironmentProbe.toolchainKeys { result[key] = toolchains[key] }
        return result
    }
}

public struct CursorEnvironmentProbe: Sendable {
    static let toolchainKeys = ["JAVA_HOME", "DEVELOPER_DIR", "SDKROOT", "GOPATH"]
    public let environment: [String: String]
    public let loginShell: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, loginShell: String? = nil) {
        self.environment = environment
        if let loginShell { self.loginShell = loginShell }
        else if let shell = getpwuid(getuid())?.pointee.pw_shell { self.loginShell = String(cString: shell) }
        else { self.loginShell = "/bin/sh" }
    }

    public func resolve(_ configuration: CursorEnvironment) -> ResolvedCursorEnvironment {
        let script = #"printf 'KABAN_ENV_V1\0%s\0%s\0%s\0%s\0%s\0%s\0' "$PATH" "$(command -v cursor-agent 2>/dev/null)" "${JAVA_HOME-}" "${DEVELOPER_DIR-}" "${SDKROOT-}" "${GOPATH-}""#
        let result = CursorRunner.invoke(loginShell, ["-lc", script], environment)
        var path = environment["PATH"] ?? "/usr/bin:/bin"
        var executable = configuration.executablePath
        var toolchains = environment.filter { Self.toolchainKeys.contains($0.key) && Self.validToolchain($0.value) }
        if result.code == 0, let marker = result.stdout.range(of: "KABAN_ENV_V1\0", options: .backwards) {
            let fields = result.stdout[marker.upperBound...].split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            if fields.count == 7 {
                path = fields[0]
                if executable == nil, Self.validPath(fields[1]) { executable = fields[1] }
                toolchains = Dictionary(uniqueKeysWithValues: zip(Self.toolchainKeys, fields.dropFirst(2).prefix(4)).filter { Self.validToolchain($0.1) })
            }
        }
        return .init(configuration: .init(executablePath: executable), searchPath: path, toolchains: toolchains)
    }

    public static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0") && !path.contains("\n") && !path.contains("\r")
    }

    private static func validToolchain(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { validPath(String($0)) }
    }
}
