import XCTest
import KabanProtocol
@testable import KabanKit

final class GitPolicyTests: XCTestCase {
    func testPresetsAndOverrides() throws {
        let c = try XCTUnwrap(PipelineValidator.validate(yaml: try Fixtures.text("good-full.yaml"), context: .init(mcpAllowlist: ["github"])).config)
        let dev = try XCTUnwrap(c.stage("dev"))
        let normal = GitPolicyResolver.resolve(project: c.git, stage: dev, returnReason: nil)
        XCTAssertEqual(normal.allowed, ["status", "diff", "log", "show", "add", "commit", "restore --staged", "stash"])
        XCTAssertFalse(normal.allows("rebase"))
        XCTAssertEqual(normal.committer, .agentWithSafetyCommit)
        let conflict = GitPolicyResolver.resolve(project: c.git, stage: dev, returnReason: .mergeConflict)
        XCTAssertTrue(conflict.allows("rebase"))
        XCTAssertFalse(conflict.allows("push"))

        let review = try XCTUnwrap(c.stage("ai_review"))
        let ro = GitPolicyResolver.resolve(project: c.git, stage: review, returnReason: nil)
        XCTAssertEqual(ro.allowed, ["status", "diff", "log", "show"])
        XCTAssertTrue(ro.readOnly)

        let strict = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .strict), stage: dev, returnReason: nil)
        XCTAssertEqual(strict.committer, .daemonOnly)
        XCTAssertFalse(strict.allows("commit"))

        let permissive = GitPolicyResolver.resolve(project: ProjectGitPolicy(preset: .permissive, deny: ["reset"]), stage: dev, returnReason: nil)
        XCTAssertTrue(permissive.allows("rebase"))
        XCTAssertFalse(permissive.allows("reset"))
        XCTAssertTrue(GitPolicyResolver.violatesHardInvariant("push origin main"))
        XCTAssertTrue(GitPolicyResolver.violatesHardInvariant("commit --force"))
        XCTAssertFalse(GitPolicyResolver.violatesHardInvariant("rebase"))
    }
}

final class SuspiciousFilesTests: XCTestCase {
    let policy = SuspiciousFilesPolicy()

    func testPatternsAllowAndSize_SUSP01_SUSP02() {
        let files = [
            ChangedFile(path: ".env.local", sizeBytes: 212, blob: "a1b2c3"),
            ChangedFile(path: ".env.example", sizeBytes: 90, blob: "e0e0e0"),
            ChangedFile(path: "certs/server.pem", sizeBytes: 10, blob: "p1"),
            ChangedFile(path: "src/main.swift", sizeBytes: 10, blob: "s1"),
            ChangedFile(path: "assets/dump.bin", sizeBytes: 7_340_032, blob: "d4e5f6"),
            ChangedFile(path: "old/id_rsa", sizeBytes: 1, blob: "k", deleted: true),
        ]
        let found = SuspiciousFilesScanner.scan(files, policy: policy)
        XCTAssertEqual(found.map(\.path), [".env.local", "assets/dump.bin", "certs/server.pem"])
        XCTAssertEqual(found.map(\.rule), [.pattern, .size, .pattern])
        XCTAssertEqual(found[0].pattern, ".env*")

        // Accepted (path, blob) does not fire again; same path with a new blob does.
        let accepted: Set<FileBlobRef> = [FileBlobRef(path: ".env.local", blob: "a1b2c3"), FileBlobRef(path: "certs/server.pem", blob: "p1")]
        XCTAssertEqual(SuspiciousFilesScanner.scan(files, policy: policy, accepted: accepted).map(\.path), ["assets/dump.bin"])
        let changed = [ChangedFile(path: ".env.local", sizeBytes: 230, blob: "ffff01")]
        XCTAssertEqual(SuspiciousFilesScanner.scan(changed, policy: policy, accepted: accepted).map(\.path), [".env.local"])
    }

    func testGlob() {
        XCTAssertTrue(SuspiciousFilesScanner.matches(pattern: "*.key", path: "a/b/c.key"))
        XCTAssertFalse(SuspiciousFilesScanner.matches(pattern: "*.key", path: "a/b/c.keys"))
        XCTAssertTrue(SuspiciousFilesScanner.matches(pattern: "config/*.json", path: "config/a.json"))
        XCTAssertFalse(SuspiciousFilesScanner.matches(pattern: "config/*.json", path: "config/x/a.json"))
        XCTAssertTrue(SuspiciousFilesScanner.matches(pattern: "config/**.json", path: "config/x/a.json"))
        XCTAssertTrue(SuspiciousFilesScanner.matches(pattern: "id_?sa*", path: "id_rsa.pub"))
    }

    func testSameSet() {
        let cur = [SuspiciousFile(path: "a", rule: .pattern, sizeBytes: 1, blob: "1"), SuspiciousFile(path: "b", rule: .size, sizeBytes: 9, blob: "2")]
        XCTAssertTrue(SuspiciousFilesScanner.sameSet(cur, [FileBlobRef(path: "b", blob: "2"), FileBlobRef(path: "a", blob: "1")]))
        XCTAssertFalse(SuspiciousFilesScanner.sameSet(cur, [FileBlobRef(path: "a", blob: "1")]))
        XCTAssertFalse(SuspiciousFilesScanner.sameSet(cur, [FileBlobRef(path: "a", blob: "1"), FileBlobRef(path: "b", blob: "3")]))
    }
}
