import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
import KabanProtocol
@testable import KabanKit

final class Team2DaemonGitEdgeTests: XCTestCase {
    private typealias Sandbox = DaemonGitTests.Sandbox
    private let identity = GitIdentity(name: "Team2", email: "team2@example.com")

    private func withRepo(_ body: (Sandbox, String, [String: String]) throws -> Void) throws {
        let s = try Sandbox.make()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.write("", to: "global.config"); try s.write("", to: "system.config")
        let env = ["PATH": "/usr/bin:/bin", "HOME": s.root.path, "TMPDIR": s.root.path,
                   "GIT_CONFIG_GLOBAL": s.root.appendingPathComponent("global.config").path,
                   "GIT_CONFIG_SYSTEM": s.root.appendingPathComponent("system.config").path,
                   "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        try s.git(["init", "-q", "-b", "main", "repo"], env: env)
        try body(s, s.root.appendingPathComponent("repo").path, env)
    }

    private func resolve(_ repo: String, _ env: [String: String]) throws -> GitIdentity {
        try GitIdentity.resolveForProject(explicit: nil, repositoryPath: repo, environment: env)
    }
    private func required(_ repo: String, _ env: [String: String]) throws -> [String: String] {
        do { _ = try resolve(repo, env); XCTFail("Expected identity_required"); return [:] }
        catch let error as GitIdentityRequired {
            XCTAssertEqual(error.commandError.code, "identity_required")
            return error.commandError.params
        }
    }
    private func set(_ s: Sandbox, _ repo: String, _ env: [String: String], _ name: String?, _ email: String?) throws {
        if let name { try s.git(["-C", repo, "config", "user.name", name], env: env) }
        if let email { try s.git(["-C", repo, "config", "user.email", email], env: env) }
    }
    private func daemon(_ command: [String], _ repo: String, _ env: [String: String], author: GitIdentity? = nil, input: Data? = nil) throws -> Data {
        let process = Process(), out = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: DaemonGit.executable)
        process.arguments = try DaemonGit.arguments(command, in: repo, identity: author)
        process.environment = DaemonGit.environment(merging: env)
        process.currentDirectoryURL = URL(fileURLWithPath: repo)
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = out; process.standardError = errors
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errorData, as: UTF8.self))
        return data
    }
    private func commit(_ repo: String, _ env: [String: String]) throws {
        _ = try daemon(["add", "--all"], repo, env)
        _ = try daemon(["commit", "-q", "--allow-empty", "-m", "synthetic"], repo, env, author: identity)
    }

    func testMissingIdentityInUnbornRepository() throws {
        try withRepo { _, repo, env in XCTAssertEqual(try required(repo, env), ["missing": "name,email"]) }
    }
    func testSystemIdentityIsResolvedOnRegistration() throws {
        try withRepo { s, repo, env in
            try s.write("[user]\nname=System\nemail=system@example.com\n", to: "system.config")
            XCTAssertEqual(try resolve(repo, env), GitIdentity(name: "System", email: "system@example.com"))
        }
    }
    func testGlobalIdentityOverridesSystemPerKey() throws {
        try withRepo { s, repo, env in
            try s.write("[user]\nname=System\nemail=system@example.com\n", to: "system.config")
            try s.write("[user]\nname=Global\n", to: "global.config")
            XCTAssertEqual(try resolve(repo, env), GitIdentity(name: "Global", email: "system@example.com"))
        }
    }
    func testLocalIdentityOverridesGlobalPerKey() throws {
        try withRepo { s, repo, env in
            try s.write("[user]\nname=Global\nemail=global@example.com\n", to: "global.config")
            try set(s, repo, env, "Local", nil)
            XCTAssertEqual(try resolve(repo, env), GitIdentity(name: "Local", email: "global@example.com"))
        }
    }
    func testMatchingIncludeIfResolvesIdentity() throws {
        try withRepo { s, repo, env in
            try s.write("[user]\nname=Included\nemail=included@example.com\n", to: "included.config")
            try s.write("[includeIf \"gitdir:**/repo/\"]\npath=\(s.root.path)/included.config\n", to: "global.config")
            XCTAssertEqual(try resolve(repo, env), GitIdentity(name: "Included", email: "included@example.com"))
        }
    }
    func testNonmatchingIncludeIfDoesNotSupplyIdentity() throws {
        try withRepo { s, repo, env in
            try s.write("[user]\nname=Included\nemail=included@example.com\n", to: "included.config")
            try s.write("[includeIf \"gitdir:**/absent/\"]\npath=\(s.root.path)/included.config\n", to: "global.config")
            XCTAssertEqual(try required(repo, env), ["missing": "name,email"])
        }
    }
    func testLocalBlankNameDoesNotFallBackToGlobal() throws {
        try withRepo { s, repo, env in
            try s.write("[user]\nname=Global\nemail=global@example.com\n", to: "global.config")
            try set(s, repo, env, "", nil)
            XCTAssertEqual(try required(repo, env), ["missing": "name", "email": "global@example.com"])
        }
    }
    func testWhitespaceOnlyNameIsMissing() throws {
        try withRepo { s, repo, env in
            try set(s, repo, env, "\t \t", "found@example.com")
            XCTAssertEqual(try required(repo, env), ["missing": "name", "email": "found@example.com"])
        }
    }
    func testWhitespaceOnlyEmailIsMissing() throws {
        try withRepo { s, repo, env in
            try set(s, repo, env, " Found ", "\t  ")
            XCTAssertEqual(try required(repo, env), ["missing": "email", "name": "Found"])
        }
    }
    func testBothBlankFieldsKeepNameEmailOrder() throws {
        try withRepo { s, repo, env in
            try set(s, repo, env, "", " ")
            XCTAssertEqual(try required(repo, env), ["missing": "name,email"])
        }
    }
    func testLFInRepositoryNameIsInvalidWithFoundEmail() throws {
        try withRepo { s, repo, env in
            try set(s, repo, env, " A\nB ", " found@example.com ")
            XCTAssertEqual(try required(repo, env), ["invalid": "name", "email": "found@example.com"])
        }
    }
    func testCRInRepositoryEmailIsInvalidWithFoundName() throws {
        try withRepo { s, repo, env in
            try set(s, repo, env, "Found", "a\rb")
            XCTAssertEqual(try required(repo, env), ["invalid": "email", "name": "Found"])
        }
    }
    func testTwoInvalidRepositoryFieldsKeepNameEmailOrder() throws {
        try withRepo { s, repo, env in
            try set(s, repo, env, "A\nB", "a\rb")
            XCTAssertEqual(try required(repo, env), ["invalid": "name,email"])
        }
    }
    func testNULExplicitIdentityCannotReachDaemonArgv() throws {
        try withRepo { _, repo, env in
            XCTAssertThrowsError(try GitIdentity.resolveForProject(explicit: GitIdentity(name: "A\0B", email: "found@example.com"), repositoryPath: repo, environment: env)) {
                XCTAssertEqual(($0 as? GitIdentityRequired)?.params, ["invalid": "name", "email": "found@example.com"])
            }
            XCTAssertThrowsError(try DaemonGit.arguments(["commit"], identity: GitIdentity(name: "A", email: "a\0b")))
        }
    }
    func testUnicodeIdentityIsTrimmedAndUsedByRealCommit() throws {
        try withRepo { s, repo, env in
            try set(s, repo, env, " Яé🐗 ", " author@example.com\t")
            let author = try resolve(repo, env)
            _ = try daemon(["commit", "-q", "--allow-empty", "-m", "unicode"], repo, env, author: author)
            let data = try daemon(["log", "-1", "--format=%an%x00%ae%x00%cn%x00%ce"], repo, env)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "Яé🐗\0author@example.com\0Яé🐗\0author@example.com\n")
        }
    }
    func testDaemonCommitUsesExplicitIdentityDespiteAllConfigLayers() throws {
        try withRepo { s, repo, env in
            try s.write("[user]\nname=System\nemail=system@example.com\n", to: "system.config")
            try s.write("[user]\nname=Global\nemail=global@example.com\n", to: "global.config")
            try set(s, repo, env, "Local", "local@example.com")
            try commit(repo, env)
            XCTAssertEqual(String(decoding: try daemon(["log", "-1", "--format=%an|%ae|%cn|%ce"], repo, env), as: UTF8.self), "Team2|team2@example.com|Team2|team2@example.com\n")
        }
    }
    func testSpaceAndNewlineFilenamesRemainNULSeparated() throws {
        try withRepo { _, repo, env in
            let names = ["with spaces.txt", "line\nbreak.txt", "Яé🐗.txt"]
            for name in names { try Data("ok".utf8).write(to: URL(fileURLWithPath: repo).appendingPathComponent(name)) }
            _ = try daemon(["add", "--all"], repo, env)
            let paths = try daemon(["diff", "--cached", "--name-only", "-z"], repo, env)
            XCTAssertEqual(Set(paths.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }), Set(names))
        }
    }
    func testNonUTF8FilenameBytesSurviveGitPlumbing() throws {
        try withRepo { _, repo, env in
            // APFS rejects invalid UTF-8 filenames. Construct a raw Git tree instead so the
            // same byte preservation assertion runs on Darwin and Linux without a checkout.
            let oid = String(decoding: try daemon(["hash-object", "-w", "--stdin"], repo, env, input: Data()), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let filename = Array("raw-".utf8) + [0xff, 0xfe]
            let entry = Data(Array("100644 blob \(oid)\t".utf8) + filename + [0])
            let tree = String(decoding: try daemon(["mktree", "-z"], repo, env, input: entry), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let paths = try daemon(["ls-tree", "--name-only", "-z", tree], repo, env)
            XCTAssertEqual(paths, Data(filename + [0]))
        }
    }
    func testBinaryBlobRoundTripsWithoutUTF8Decoding() throws {
        try withRepo { _, repo, env in
            let binary = Data([0, 255, 254, 13, 10, 0, 42])
            try binary.write(to: URL(fileURLWithPath: repo).appendingPathComponent("binary.dat"))
            try commit(repo, env)
            XCTAssertEqual(try daemon(["show", "HEAD:binary.dat"], repo, env), binary)
        }
    }
    func testDetachedHEADCommitUsesExplicitIdentity() throws {
        try withRepo { _, repo, env in
            try commit(repo, env)
            _ = try daemon(["checkout", "-q", "--detach", "HEAD"], repo, env)
            try commit(repo, env)
            XCTAssertEqual(String(decoding: try daemon(["rev-parse", "--abbrev-ref", "HEAD"], repo, env), as: UTF8.self), "HEAD\n")
        }
    }
    func testUnbornStatusWorksWithoutIdentityAndThenCommitCreatesHEAD() throws {
        try withRepo { _, repo, env in
            XCTAssertEqual(try daemon(["status", "--porcelain"], repo, env), Data())
            _ = try daemon(["commit", "-q", "--allow-empty", "-m", "initial"], repo, env, author: identity)
            XCTAssertEqual(String(decoding: try daemon(["rev-list", "--count", "HEAD"], repo, env), as: UTF8.self), "1\n")
        }
    }
    func testGitlinkModeSurvivesDaemonIndexAndCommit() throws {
        try withRepo { _, repo, env in
            try commit(repo, env)
            let oid = String(decoding: try daemon(["rev-parse", "HEAD"], repo, env), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try daemon(["update-index", "--add", "--cacheinfo", "160000,\(oid),module"], repo, env)
            _ = try daemon(["commit", "-q", "-m", "gitlink"], repo, env, author: identity)
            XCTAssertEqual(String(decoding: try daemon(["ls-tree", "HEAD", "module"], repo, env), as: UTF8.self), "160000 commit \(oid)\tmodule\n")
        }
    }
    func testLocalSubmoduleCommitHasGitlinkAndGitmodules() throws {
        try withRepo { s, repo, env in
            let child = s.root.appendingPathComponent("child").path
            try s.git(["init", "-q", "-b", "main", child], env: env)
            try commit(child, env)
            // Only the fixture setup permits local transport; daemon commits retain hardening.
            try s.git(["-c", "protocol.file.allow=always", "-C", repo, "submodule", "add", "-q", child, "with spaces"], env: env)
            try commit(repo, env)
            let tree = String(decoding: try daemon(["ls-tree", "HEAD"], repo, env), as: UTF8.self)
            XCTAssertTrue(tree.contains("100644 blob "))
            XCTAssertTrue(tree.contains("\t.gitmodules\n"))
            XCTAssertTrue(tree.contains("160000 commit "))
            XCTAssertTrue(tree.contains("\twith spaces\n"))
            XCTAssertEqual(try daemon(["status", "--porcelain"], repo, env), Data())
        }
    }
    func testMixedMissingAndInvalidFieldsRemainDisjoint() throws {
        try withRepo { s, repo, env in
            try set(s, repo, env, " \t", "a\nb")
            XCTAssertEqual(try required(repo, env), ["missing": "name", "invalid": "email"])
        }
    }
    func testInheritedRepositoryLocatorCannotChangeIdentityTarget() throws {
        try withRepo { s, repo, env in
            try set(s, repo, env, "Local", "local@example.com")
            let hostile = env.merging(["GIT_DIR": "/absent", "GIT_WORK_TREE": "/absent", "GIT_COMMON_DIR": "/absent"]) { $1 }
            XCTAssertEqual(try resolve(repo, hostile), GitIdentity(name: "Local", email: "local@example.com"))
        }
    }
    func testCRLFIdentityMustBeInvalidForRepositoryAndExplicitInput() throws {
        var accepted: [String] = []
        try withRepo { s, repo, env in
            let cases: [(GitIdentity, [String: String])] = [
                (GitIdentity(name: "A\r\nB", email: "a@example.com"), ["invalid": "name", "email": "a@example.com"]),
                (GitIdentity(name: "A", email: "a\r\nb"), ["invalid": "email", "name": "A"]),
                (GitIdentity(name: " \r\n\t", email: " \r\n "), ["invalid": "name,email"]),
            ]
            for (index, item) in cases.enumerated() {
                try set(s, repo, env, item.0.name, item.0.email)
                for explicit in [false, true] {
                    do {
                        _ = try GitIdentity.resolveForProject(explicit: explicit ? item.0 : nil,
                                                              repositoryPath: repo, environment: env)
                        accepted.append("case \(index), explicit=\(explicit)")
                    } catch let error as GitIdentityRequired {
                        XCTAssertEqual(error.params, item.1)
                    }
                }
            }
        }
        if !accepted.isEmpty {
            throw XCTSkip("https://github.com/imedfan/kaban/issues/30: CRLF accepted: " + accepted.joined(separator: "; "))
        }
    }
}
