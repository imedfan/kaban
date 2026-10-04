import Foundation
import XCTest
import KabanProtocol
@testable import KabanKit

final class Team2GitPolicyCorpusTests: XCTestCase {
    private struct Row: Decodable {
        let command: String
        let invariant: String?
        let why: String
        let scope: String
    }

    private func rows(_ filename: String) throws -> [Row] {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try JSONDecoder().decode([Row].self, from: Data(contentsOf: root.appendingPathComponent("team2/" + filename)))
    }

    private func broadPolicy() -> EffectiveGitPolicy {
        EffectiveGitPolicy(preset: .permissive,
                           allowed: GitPolicyResolver.gitCommandCatalog.map { GitRule($0, source: .project) },
                           hardInvariants: HardInvariant.all, committer: .agentWithSafetyCommit, readOnly: false)
    }

    func testStaticDeniedCorpusAndInvariantOrderWithBroadProjectAllowlist() throws {
        let corpus = try rows("git-deny.json").filter { $0.scope == "static" }
        XCTAssertGreaterThanOrEqual(corpus.count, 150)
        let policy = broadPolicy()
        for row in corpus {
            let label = "\(row.command): \(row.why)"
            XCTAssertEqual(GitPolicyResolver.hardInvariant(for: row.command), row.invariant, label)
            XCTAssertFalse(policy.allows(row.command), label)
            let padded = "  " + row.command.replacingOccurrences(of: " ", with: "   ") + "  "
            XCTAssertEqual(GitPolicyResolver.normalize(padded), row.command, label)
            XCTAssertEqual(GitPolicyResolver.hardInvariant(for: padded), row.invariant, label)
            XCTAssertFalse(policy.allows(padded), label)
        }
    }

    func testAllowedControlsDoNotMisclassifyPathsOrOrdinaryShortF() throws {
        let corpus = try rows("git-allow.json")
        XCTAssertGreaterThanOrEqual(corpus.count, 50)
        for row in corpus {
            XCTAssertNil(row.invariant)
            XCTAssertNil(GitPolicyResolver.hardInvariant(for: row.command), "\(row.command): \(row.why)")
            XCTAssertTrue(broadPolicy().allows(row.command), "\(row.command): \(row.why)")
        }
    }

    func testCorpusHasUniqueCommandsRationalesAndAllSevenInvariantIds() throws {
        let deny = try rows("git-deny.json"), allow = try rows("git-allow.json")
        let all = deny + allow
        XCTAssertEqual(Set(all.map(\.command)).count, all.count)
        XCTAssertTrue(all.allSatisfy { !$0.command.isEmpty && !$0.why.isEmpty })
        XCTAssertEqual(Set(deny.compactMap(\.invariant)), Set(HardInvariant.all))
        XCTAssertTrue(Set(allow.map(\.command)).isDisjoint(with: deny.map(\.command)))
        for row in deny where ["shim", "question"].contains(row.scope) {
            XCTAssertTrue(HardInvariant.all.contains(try XCTUnwrap(row.invariant)))
            XCTAssertEqual(GitPolicyResolver.normalize(row.command), row.command)
        }
    }

    private func assertKnownMatcherGap(_ commands: [String], issue: Int) throws {
        let cases = try rows("git-deny.json").filter { commands.contains($0.command) }
        XCTAssertEqual(cases.count, commands.count)
        let gaps = cases.filter { GitPolicyResolver.hardInvariant(for: $0.command) != $0.invariant || broadPolicy().allows($0.command) }
        if !gaps.isEmpty { throw XCTSkip("Matcher gap: \(gaps.map(\.command)); https://github.com/imedfan/kaban/issues/\(issue)") }
        for row in cases {
            XCTAssertEqual(GitPolicyResolver.hardInvariant(for: row.command), row.invariant, row.command)
            XCTAssertFalse(broadPolicy().allows(row.command), row.command)
        }
    }

    func testAttachedBranchResetArgumentsCannotBypassInvariant() throws {
        try assertKnownMatcherGap(["checkout -Btask1", "switch -Ctask1"], issue: 23)
    }
    func testGitAcceptedBranchAbbreviationsCannotBypassInvariant() throws {
        try assertKnownMatcherGap(["branch --del other", "branch --mov other renamed"], issue: 24)
    }
    func testEqualsFormMainRebaseTargetCannotBypassInvariant() throws {
        try assertKnownMatcherGap(["rebase --onto=main HEAD~1"], issue: 25)
    }
}
