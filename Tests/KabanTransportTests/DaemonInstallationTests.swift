import Foundation
import XCTest
import KabanTransport

final class DaemonInstallationTests: XCTestCase {
    func testPrivateLayoutSeparatesDeveloperDataAndRepairsDirectoryModes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = DaemonInstallation(home: home)
        let developer = DaemonInstallation(home: home, developer: true)
        XCTAssertNotEqual(installed.database, developer.database)
        XCTAssertNotEqual(installed.workspaces, developer.workspaces)
        try installed.prepare(); try developer.prepare()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.data.path)
        try installed.prepare()
        for directory in [installed.data, installed.logs, installed.workspaces, developer.data, developer.logs, developer.workspaces] {
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        XCTAssertEqual(installed.database.lastPathComponent, "store.sqlite")
    }
    func testSymlinkWorkspaceDoesNotChangeExternalDirectoryPermissions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = DaemonInstallation(home: home)
        try installed.prepare()
        let external = home.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.removeItem(at: installed.workspaces)
        try FileManager.default.createSymbolicLink(at: installed.workspaces, withDestinationURL: external)
        XCTAssertThrowsError(try installed.prepare())
        let attrs = try FileManager.default.attributesOfItem(atPath: external.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }
    func testExistingDatabaseIsPrivateAndSymlinkLogFailsClosed() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = DaemonInstallation(home: home)
        try installed.prepare()
        try Data("private".utf8).write(to: installed.database)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installed.database.path)
        try installed.prepare()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: installed.database.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.createSymbolicLink(at: installed.logs.appendingPathComponent("daemon.log"), withDestinationURL: installed.database)
        XCTAssertThrowsError(try installed.prepare())
    }
    #if os(macOS)
    func testUnbundledAndUnsignedPeersFailClosed() throws {
        guard #available(macOS 26.0, *) else { return }
        XCTAssertThrowsError(try BundledDaemonIdentity.appBundle(containing: URL(fileURLWithPath: "/usr/bin/true")))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("unsigned".utf8).write(to: file)
        XCTAssertThrowsError(try BundledDaemonIdentity.inspect(file, identifier: DaemonInstallation.helperIdentifier))
        XCTAssertThrowsError(try BundledDaemonIdentity.inspect(URL(fileURLWithPath: "/usr/bin/true"), identifier: DaemonInstallation.helperIdentifier))
    }
    #endif
}
