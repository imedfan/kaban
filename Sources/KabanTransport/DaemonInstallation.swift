import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Stable, per-user host layout. Developer data never shares the installed writer's DB.
public struct DaemonInstallation: Sendable, Equatable {
    public static let appIdentifier = "app.kaban.desktop"
    public static let helperIdentifier = "app.kaban.agent"
    public static let plistName = "app.kaban.agent.plist"
    public let data: URL
    public let logs: URL
    public var database: URL { data.appendingPathComponent("store.sqlite") }
    public var workspaces: URL { data.appendingPathComponent("Workspaces", isDirectory: true) }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, developer: Bool = false) {
        let suffix = developer ? "Kaban/Development" : "Kaban"
        data = home.resolvingSymlinksInPath().appendingPathComponent("Library/Application Support/" + suffix, isDirectory: true)
        logs = home.resolvingSymlinksInPath().appendingPathComponent("Library/Logs/" + suffix, isDirectory: true)
    }
    public func prepare() throws {
        for directory in [data, logs, workspaces] {
            if FileManager.default.fileExists(atPath: directory.path) {
                let values = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard values[.type] as? FileAttributeType == .typeDirectory, (values[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw CocoaError(.fileWriteInvalidFileName) }
            }
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        for file in [database, URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm"), URL(fileURLWithPath: database.path + ".daemon.lock"), logs.appendingPathComponent("daemon.log")] {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let values = try FileManager.default.attributesOfItem(atPath: file.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  (values[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
                  file.resolvingSymlinksInPath().path == file.path else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}

#if os(macOS)
import Security
import XPC
import LightweightCodeRequirements

/// Both peers derive their policy from the sealed bundle. Apple certificates use
/// same-team + signing ID; personal ad-hoc builds pin the exact peer code directory.
@available(macOS 26.0, *)
public enum BundledDaemonIdentity {
    public enum Failure: Error { case notBundled, invalidSignature(OSStatus), wrongIdentifier, differentTeam, missingHash }
    public struct Identity: Sendable {
        public let identifier: String
        public let team: String?
        public let hashes: [Data]
    }
    public static func appBundle(containing executable: URL) throws -> URL {
        var location = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while location.path != "/" {
            if location.pathExtension == "app" { return location }
            location.deleteLastPathComponent()
        }
        throw Failure.notBundled
    }
    public static func inspect(_ url: URL, identifier: String) throws -> Identity {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw Failure.invalidSignature(status) }
        status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard status == errSecSuccess else { throw Failure.invalidSignature(status) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let values = information as? [String: Any] else { throw Failure.invalidSignature(status) }
        guard values[kSecCodeInfoIdentifier as String] as? String == identifier else { throw Failure.wrongIdentifier }
        let hashes = (values[kSecCodeInfoCdHashes as String] as? [Data]) ?? (values[kSecCodeInfoUnique as String] as? Data).map { [$0] } ?? []
        guard !hashes.isEmpty else { throw Failure.missingHash }
        return Identity(identifier: identifier, team: values[kSecCodeInfoTeamIdentifier as String] as? String, hashes: hashes)
    }
    public static func requirement(appBundle: URL, forHelper: Bool) throws -> XPCPeerRequirement {
        let app = try inspect(appBundle, identifier: DaemonInstallation.appIdentifier)
        let helper = try inspect(appBundle.appendingPathComponent("Contents/MacOS/KabanDaemon"), identifier: DaemonInstallation.helperIdentifier)
        let peer = forHelper ? helper : app
        if let team = app.team {
            guard helper.team == team else { throw Failure.differentTeam }
            return .isFromSameTeam(andMatchesSigningIdentifier: peer.identifier)
        }
        guard helper.team == nil else { throw Failure.differentTeam }
        let requirement = try ProcessCodeRequirement.allOf {
            SigningIdentifier(peer.identifier)
            CodeDirectoryHash.in(peer.hashes)
        }
        return .codeRequirement(requirement)
    }
}
#endif
