import Foundation
import XCTest
@testable import KabanProtocol

/// Малый протокольный PR (арх. v0.11.2): новые поля необязательны на проводе,
/// старый демон и старые сценарии M1 читаются с дефолтами.
final class CompatTests: XCTestCase {
    let decoder = KabanCoding.makeDecoder()

    func legacy(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/legacy"),
                                "нет legacy-фикстуры \(name)")
        return try Data(contentsOf: url)
    }

    func testLegacySnapshotDecodesWithDefaults() throws {
        let s = try decoder.decode(Snapshot.self, from: try legacy("snapshot.json"))
        XCTAssertEqual(s.stageLoad, [])
        XCTAssertTrue(s.projects.allSatisfy { $0.openIncidentCount == 0 })
        XCTAssertTrue(s.tasks.allSatisfy { !$0.hasAcceptanceCriteria })
        XCTAssertTrue(s.tasks.flatMap(\.suspiciousFiles).allSatisfy { !$0.isText })
        for stage in s.pipelines.flatMap(\.stages) {
            XCTAssertEqual(stage.gates, [])
            XCTAssertNil(stage.onFail)
            XCTAssertNil(stage.onConflict)
        }
        XCTAssertTrue(s.pipelines.flatMap(\.issues).allSatisfy { $0.stageId == nil })
        XCTAssertTrue(s.pipelines.allSatisfy { $0.defaultReturnStage == nil })
        XCTAssertTrue(s.pipelines.allSatisfy { $0.projectGitPolicy == nil && $0.gitCommandCatalog.isEmpty })
    }

    func testLegacyJournalDecodes() throws {
        let events = try decoder.decode([EventEnvelope].self, from: try legacy("journal-events.json"))
        XCTAssertFalse(events.isEmpty)
    }

    func testStageLoadChangedWireName() throws {
        let e = EventEnvelope(seq: 1, at: Samples.t0, projectId: Samples.project,
                              event: .stageLoadChanged(StageLoad(projectId: Samples.project, stageId: "dev", wipUsed: 1, wipLimit: nil)))
        let json = try JSONSerialization.jsonObject(with: KabanCoding.makeEncoder().encode(e)) as! [String: Any]
        let event = json["event"] as! [String: Any]
        XCTAssertEqual(event["type"] as? String, "stageLoadChanged")
        XCTAssertNil((event["data"] as! [String: Any])["wipLimit"], "nil-лимит не пишется на провод")
        XCTAssertEqual(try decoder.decode(EventEnvelope.self, from: KabanCoding.makeEncoder().encode(e)), e)
    }

    func testReadonlyViolationWire() throws {
        XCTAssertEqual(RetryWaitReason.readonlyViolation.rawValue, "readonly_violation")
        XCTAssertEqual(RunEndReason.readonlyViolation.rawValue, "readonly_violation")
    }

    /// §3.1 v0.11.2: в Human Review место занимают все, кроме `queued`; в agent/gate/merge — прежнее правило.
    func testOccupiesWIPByStageKind() {
        XCTAssertTrue(TaskStatus.waitingHuman.occupiesWIP(in: .human))
        XCTAssertTrue(TaskStatus.blocked.occupiesWIP(in: .human))
        XCTAssertFalse(TaskStatus.queued.occupiesWIP(in: .human))
        XCTAssertFalse(TaskStatus.waitingHuman.occupiesWIP(in: .agent))
        XCTAssertTrue(TaskStatus.running.occupiesWIP(in: .agent))
        XCTAssertFalse(TaskStatus.running.occupiesWIP(in: .queue))
        XCTAssertFalse(TaskStatus.done.occupiesWIP(in: .terminal))
        for s in TaskStatus.allCases {
            XCTAssertEqual(s.occupiesWIP(in: .merge), s.occupiesWIP)
            XCTAssertEqual(s.occupiesWIP(in: .gate), s.occupiesWIP)
        }
    }

    func testNewValidationCodes() {
        XCTAssertEqual([ValidationCode.yamlSyntax, ValidationCode.duplicateId, ValidationCode.unknownStage,
                        ValidationCode.onSuccessCycle, ValidationCode.gitHardInvariant, ValidationCode.noReturnTarget],
                       ["yaml_syntax", "duplicate_id", "unknown_stage", "on_success_cycle", "git_hard_invariant", "no_return_target"])
    }

    /// Арх. v0.11.8–v0.11.10: неизвестный `source` правила и отсутствующий `params` не ломают декодирование.
    func testUnknownGitRuleSourceAndMissingParams() throws {
        let rule = try decoder.decode(GitRule.self, from: Data(#"{"rule":"rebase","source":"org_policy"}"#.utf8))
        XCTAssertEqual(rule, GitRule("rebase", source: nil))
        let issue = try decoder.decode(ValidationIssue.self,
            from: Data(#"{"path":"stages[0]","code":"x","message":"m","severity":"warning"}"#.utf8))
        XCTAssertEqual(issue.params, [:])
        let policy = try decoder.decode(EffectiveGitPolicy.self, from: Data(
            #"{"preset":"strict","allowed":[{"rule":"status","source":"preset"}],"committer":"daemon_only","readOnly":false}"#.utf8))
        XCTAssertEqual(policy.hardInvariants, [])
        XCTAssertEqual(policy.denied, [])
    }

    /// Старый клиент шлёт `addProject` без `identity` (арх. v0.11.19).
    func testAddProjectWithoutIdentity() throws {
        let cmd = try decoder.decode(Command.self,
            from: Data(#"{"addProject":{"path":"/p","createTemplate":true}}"#.utf8))
        XCTAssertEqual(cmd, .addProject(path: "/p", createTemplate: true, identity: nil))
        let set = Command.setProjectIdentity(projectId: ProjectID(rawValue: "p1"), identity: GitIdentity(name: "Artem", email: "a@x.io"))
        let back = try decoder.decode(Command.self, from: try KabanCoding.makeEncoder().encode(set))
        XCTAssertEqual(back, set)
    }

    /// Старый демон: `CommandError` без `params`, `ProjectSummary` без `identity` (арх. v0.11.20).
    func testCommandErrorParamsAndProjectIdentity() throws {
        let err = try decoder.decode(CommandError.self, from: Data(#"{"code":"identity_required","message":"m"}"#.utf8))
        XCTAssertEqual(err.params, [:])
        let full = CommandError(code: CommandError.identityRequiredCode, message: "m", params: ["missing": "email", "name": "Artem"])
        XCTAssertEqual(try decoder.decode(CommandError.self, from: try KabanCoding.makeEncoder().encode(full)), full)
        let project = try decoder.decode(ProjectSummary.self, from: Data(
            #"{"id":"p1","name":"n","path":"/p","baseBranch":"main","availability":"available","weight":1,"mascotSeed":"s"}"#.utf8))
        XCTAssertNil(project.identity)
    }
}
