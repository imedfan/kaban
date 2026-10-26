import Foundation

/// Installs the PATH entry for the compiled shim. No shell or Python runtime is required.
public enum KabanGitShim {
    public static var bundledExecutable: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("KabanGitShim")
    }

    public static func install(at url: URL, executable: URL) throws {
        let target = executable.standardizedFileURL
        guard target.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: target.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            guard existing == target.path else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
    }
}
