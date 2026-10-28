import Foundation

/// Run-local Cursor configuration with macOS login-keychain discovery (BE-22).
/// This preserves authentication, not credential isolation; Seatbelt is a separate boundary.
public enum CursorRunHome {
    public static func prepare(_ home: URL, userHome: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(macOS)
        let source = userHome.appendingPathComponent("Library/Keychains")
        guard files.fileExists(atPath: source.path) else { return }
        let library = home.appendingPathComponent("Library")
        try files.createDirectory(at: library, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = library.appendingPathComponent("Keychains")
        if let existing = try? files.destinationOfSymbolicLink(atPath: link.path) {
            guard existing == source.path else { throw CocoaError(.fileWriteFileExists) }
        } else {
            try files.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
        }
        #endif
    }
}
