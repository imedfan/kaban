import XCTest
import KabanKit

final class GitCheckTests: XCTestCase {
    func testNormalizationCollapsesGitGlobalsOntoConfig() {
        XCTAssertEqual(GitCheck.normalize(argv: ["git", "status"]), ["status"])
        XCTAssertEqual(GitCheck.normalize(argv: ["/usr/bin/git", "--no-pager", "status"]), ["status"])
        XCTAssertEqual(GitCheck.normalize(argv: ["git", "-C", "/elsewhere", "status"]), ["config"])
        XCTAssertEqual(GitCheck.normalize(argv: ["git", "-c", "core.hooksPath=/tmp", "status"]), ["config"])
        XCTAssertEqual(GitCheck.normalize(argv: ["git", "--git-dir=/tmp/other", "status"]), ["config"])
        XCTAssertEqual(GitCheck.blocked(["config"]), "config")
        XCTAssertEqual(GitCheck.blocked(["push", "origin", "main"]), "push")
        XCTAssertEqual(GitCheck.blocked(["add", ".kaban/pipeline.yaml"]), "kaban_dir")
        XCTAssertNil(GitCheck.blocked(["status", ".kaban/pipeline.yaml"]))
        XCTAssertFalse(GitCheck.sameCommand(["rebase"], ["rebase", "main"]))
        XCTAssertTrue(GitCheck.sameCommand(["git", "rebase", "feature"], ["rebase", "feature"]))
    }

    func testCursorRulesLeaveConfigurableDeniesToTheShim() {
        let rules = GitCheck.cursorDenyRules(configurableDenies: ["commit", "rebase", "cherry-pick"])
        XCTAssertEqual(rules, GitCheck.cursorHardDenyCommands)
        XCTAssertFalse(rules.contains("commit"))
        XCTAssertFalse(rules.contains("rebase"))
        XCTAssertFalse(KabanGitShim.script.contains("rebase"))
        XCTAssertFalse(KabanGitShim.script.contains("commit"))
        XCTAssertTrue(KabanGitShim.script.contains(KabanGitShim.defaultCheckURL))
        XCTAssertTrue(KabanGitShim.script.contains("\"allow\":true") || KabanGitShim.script.contains("allow") )
    }
}
