import Foundation
import XCTest
import KabanProtocol
@testable import KabanKit

final class Team2TakeoverGitPolicyTests: XCTestCase {
    private func withRepository(_ body: (String, [String: String]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-takeover-git-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global"), system = root.appendingPathComponent("system")
        try Data().write(to: global); try Data().write(to: system)
        let env = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
                   "GIT_CONFIG_GLOBAL": global.path, "GIT_CONFIG_SYSTEM": system.path,
                   "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Synthetic", "GIT_AUTHOR_EMAIL": "test@example.com",
                   "GIT_COMMITTER_NAME": "Synthetic", "GIT_COMMITTER_EMAIL": "test@example.com"]
        let repo = root.appendingPathComponent("repo").path
        _ = try git(["init", "-q", "-b", "main", repo], env: env)
        _ = try git(["-C", repo, "commit", "-q", "--allow-empty", "-m", "first"], env: env)
        _ = try git(["-C", repo, "branch", "task1"], env: env)
        _ = try git(["-C", repo, "commit", "-q", "--allow-empty", "-m", "second"], env: env)
        try body(repo, env)
    }
    private func git(_ arguments: [String], env: [String: String]) throws -> String {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: DaemonGit.executable)
        process.arguments = arguments; process.environment = env
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SyntheticGit", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: errors, as: UTF8.self)])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    private func policy(_ command: String) -> EffectiveGitPolicy {
        GitPolicyResolver.resolve(project: .init(preset: .permissive, allow: [command.split(separator: " ").first.map(String.init)!]),
                                  stage: StageConfig(id: "dev", kind: .agent, agent: .init(model: "test")))
    }
    func testAttachedBranchResetOptionsAreDeniedAndReallyMoveExistingRef() throws {
        for command in [["checkout", "-Btask1"], ["checkout", "-qBtask1"], ["switch", "-Ctask1"], ["switch", "-qCtask1"]] {
            try withRepository { repo, env in
                let text = command.joined(separator: " ")
                XCTAssertEqual(GitPolicyResolver.hardInvariant(for: text), HardInvariant.foreignRefs, text)
                XCTAssertFalse(policy(text).allows(text), text)
                let before = try git(["-C", repo, "rev-parse", "task1"], env: env)
                _ = try git(["-C", repo] + command, env: env)
                XCTAssertNotEqual(try git(["-C", repo, "rev-parse", "task1"], env: env), before)
            }
        }
    }
    func testSupportedLongBranchMutationAbbreviationsAreDenied() throws {
        for command in [["branch", "--del", "task1"], ["branch", "--delet", "task1"],
                        ["branch", "--mov", "task1", "renamed"], ["branch", "--move", "task1", "renamed"]] {
            try withRepository { repo, env in
                let text = command.joined(separator: " ")
                XCTAssertEqual(GitPolicyResolver.hardInvariant(for: text), HardInvariant.foreignRefs, text)
                XCTAssertFalse(policy(text).allows(text), text)
                _ = try git(["-C", repo] + command, env: env)
                let refs = try git(["-C", repo, "branch", "--format=%(refname:short)"], env: env)
                XCTAssertFalse(refs.split(separator: "\n").contains("task1"))
            }
        }
    }
    func testEqualsFormMainRebaseTargetIsDeniedAndRecognizedByGit() throws {
        for onto in ["--onto=main", "--onto=refs/heads/main", "--onto=main~1", "--ont=main"] {
            try withRepository { repo, env in
                _ = try git(["-C", repo, "checkout", "-q", "-b", "work"], env: env)
                let command = ["rebase", onto, "HEAD~1"]
                let text = command.joined(separator: " ")
                XCTAssertEqual(GitPolicyResolver.hardInvariant(for: text), HardInvariant.foreignRefs, text)
                XCTAssertFalse(policy(text).allows(text), text)
                _ = try git(["-C", repo] + command, env: env)
            }
        }
    }
    func testAllowedBranchCreationValuesAreNotInterpretedAsShortFlags() throws {
        for command in [["checkout", "-bfeature"], ["checkout", "-qbfeature1"],
                        ["switch", "-cfeature"], ["switch", "-qcfeature1"]] {
            try withRepository { repo, env in
                let text = command.joined(separator: " ")
                XCTAssertNil(GitPolicyResolver.hardInvariant(for: text), text)
                XCTAssertTrue(policy(text).allows(text), text)
                _ = try git(["-C", repo] + command, env: env)
            }
        }
        try withRepository { repo, env in
            let text = "rebase --onto=HEAD~1 HEAD~1"
            XCTAssertNil(GitPolicyResolver.hardInvariant(for: text))
            XCTAssertTrue(policy(text).allows(text))
            _ = try git(["-C", repo, "rebase", "--onto=HEAD~1", "HEAD~1"], env: env)
        }
        for text in ["checkout -- -Btask1", "switch -- -Ctask1", "grep -f patterns", "clean -n -efoo"] {
            XCTAssertNil(GitPolicyResolver.hardInvariant(for: text), text)
        }
        XCTAssertEqual(GitPolicyResolver.hardInvariant(for: "push --force"), HardInvariant.push)
        XCTAssertEqual(GitPolicyResolver.hardInvariant(for: "checkout -f main"), HardInvariant.force)
    }
}
