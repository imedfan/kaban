import Foundation
import XCTest
@testable import KabanProtocol

final class Team2DurableDetailsTests: XCTestCase {
    private let encoder = KabanCoding.makeEncoder()
    private let decoder = KabanCoding.makeDecoder()

    func testLegacyDetailDefaultsAndFutureFields() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(Samples.taskDetail)) as? [String: Any])
        XCTAssertNil(json["artifacts"]); XCTAssertNil(json["gitGrants"]); XCTAssertNil(json["gitDenials"])
        for key in ["artifacts", "gitGrants", "gitDenials", "humanRequests", "suspiciousFiles", "acceptedFiles", "clonePath"] {
            json.removeValue(forKey: key)
        }
        json["futureDetail"] = ["opaque": true]
        let detail = try decoder.decode(TaskDetail.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(detail.task, Samples.taskDetail.task)
        XCTAssertTrue(detail.artifacts.isEmpty && detail.gitGrants.isEmpty && detail.gitDenials.isEmpty)
        XCTAssertTrue(detail.humanRequests.isEmpty && detail.acceptedFiles.isEmpty && detail.suspiciousFiles.isEmpty)
        XCTAssertNil(detail.clonePath)
        for key in ["artifacts", "gitGrants", "gitDenials"] { json[key] = NSNull() }
        let nullCollections = try decoder.decode(TaskDetail.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(nullCollections.artifacts.isEmpty && nullCollections.gitGrants.isEmpty && nullCollections.gitDenials.isEmpty)
        json["gitGrants"] = "malformed"
        XCTAssertThrowsError(try decoder.decode(TaskDetail.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testDurableLifecycleSurvivesWithoutJournalOrFeed() throws {
        let created = GitGrantCreated(grantId: "g-1", denialId: "d-1", argv: ["rebase", "task-base"], by: .human)
        let delivery = GitGrantDelivered(grantId: "g-1", runId: "r-2", via: .nextPrompt)
        let consumed = GitGrantRef(grantId: "g-1", runId: "r-2")
        let grant = GitGrantSnapshot(grant: created, taskId: "t-8", stageId: "test", createdAt: Samples.t0,
                                     delivery: delivery, deliveredAt: Samples.t0, consumption: consumed, consumedAt: Samples.t0)
        let denial = GitDenied(denialId: "d-1", taskId: "t-8", runId: "r-1", argv: created.argv, rule: "project")
        var detail = Samples.taskDetail
        detail.artifacts = [TaskArtifact(id: "a-1", taskId: "t-8", runId: "r-1", stageId: "test",
                                        kind: "future_stage_output", text: "durable summary", createdAt: Samples.t0)]
        detail.gitGrants = [grant]
        detail.gitDenials = [GitDenialSnapshot(denial: denial, at: Samples.t0)]
        detail.feed = []
        let decoded = try decoder.decode(TaskDetail.self, from: encoder.encode(detail))
        XCTAssertEqual(decoded, detail)
        XCTAssertEqual(decoded.gitGrants.first?.delivery, delivery)
        XCTAssertEqual(decoded.gitGrants.first?.consumption, consumed)
        XCTAssertEqual(decoded.gitDenials.first?.denial, denial)
        XCTAssertEqual(decoded.artifacts.first?.kind, "future_stage_output")
        // Older readers ignore additions while retaining the original required detail fields.
        struct LegacyDetail: Decodable {
            let seq: Seq
            let task: TaskCard
            let feed: [FeedItem]
            let runs: [RunSummary]
        }
        let oldReader = try decoder.decode(LegacyDetail.self, from: encoder.encode(detail))
        XCTAssertEqual(oldReader.task, detail.task)
        XCTAssertEqual(oldReader.runs, detail.runs)
    }

    func testGrantLifecycleVariantsReuseEventPayloads() throws {
        let creation = GitGrantCreated(grantId: "g-1", denialId: "d-1", argv: ["status"], by: .human)
        let revocation = GitGrantRevoked(grantId: "g-1", by: .human)
        let expiry = GitGrantExpired(grantId: "g-1", reason: .taskCancelled)
        for grant in [
            GitGrantSnapshot(grant: creation, taskId: "t-1", stageId: "dev", createdAt: Samples.t0),
            GitGrantSnapshot(grant: creation, taskId: "t-1", stageId: "dev", createdAt: Samples.t0,
                             revocation: revocation, revokedAt: Samples.t0),
            GitGrantSnapshot(grant: creation, taskId: "t-1", stageId: "dev", createdAt: Samples.t0,
                             expiry: expiry, expiredAt: Samples.t0)
        ] {
            XCTAssertEqual(try decoder.decode(GitGrantSnapshot.self, from: encoder.encode(grant)), grant)
        }
    }

    func testInitialSettingsAndJournalUpdateUseSameTypedValues() throws {
        let settings = GlobalSettings(maxConcurrentRuns: 7,
                                      quotaOptions: QuotaOptions(enabled: true, consent: true, pollInterval: 900,
                                                                 thresholdCm: 12, thresholdOm: 18), quotaConsentedAt: Samples.t0)
        var snapshot = Samples.snapshot
        snapshot.settings = settings
        XCTAssertEqual(try decoder.decode(Snapshot.self, from: encoder.encode(snapshot)).settings, settings)
        let event = EventEnvelope(seq: snapshot.seq + 1, at: Samples.t0, projectId: nil,
                                  event: .settingsChanged(SettingsChange(key: "max_concurrent_runs", value: "7", settings: settings)))
        let decoded = try decoder.decode(EventEnvelope.self, from: encoder.encode(event))
        XCTAssertEqual(decoded, event)
        guard case .settingsChanged(let change) = decoded.event else { return XCTFail("wrong event") }
        XCTAssertEqual(change.settings, snapshot.settings)
    }

    func testMissingSettingsRemainUnknownAndFutureSettingsAreTolerated() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(Samples.snapshot)) as? [String: Any])
        XCTAssertNil(json["settings"])
        json.removeValue(forKey: "settings")
        XCTAssertNil(try decoder.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json)).settings)
        let legacy = try decoder.decode(SettingsChange.self, from: Data(#"{"key":"max_concurrent_runs","value":"4","future":true}"#.utf8))
        XCTAssertNil(legacy.settings)
        let legacyEncoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any])
        XCTAssertNil(legacyEncoded["settings"])
        let settings = GlobalSettings(maxConcurrentRuns: 4, quotaOptions: QuotaOptions(enabled: false, consent: false))
        var settingsJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any])
        settingsJSON["futureLimit"] = 99
        json["settings"] = settingsJSON
        XCTAssertEqual(try decoder.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json)).settings, settings)
        settingsJSON.removeValue(forKey: "maxConcurrentRuns")
        json["settings"] = settingsJSON
        XCTAssertThrowsError(try decoder.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}
