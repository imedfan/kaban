import Foundation
import XCTest
@testable import KabanBoardCore
import KabanProtocol

/// Independent `then.tasks` oracle. Existing replay compares stored cards to event.data;
/// this checks scenario expectations on successful steps and no-event steps too.
final class Team2ScenarioCoverageTests: XCTestCase {
    func testAllScenarioTaskExpectationsAfterActualCardReplay() throws {
        let directory = ProcessInfo.processInfo.environment["KABAN_SCENARIOS"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Scenarios/M1").path
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(names.count, 33)
        var assertions = 0
        let mapping = ["stage": "stageId", "autoRuns": "runsSinceHuman", "bounces": "bounceByReason"]
        let decoder = KabanCoding.makeDecoder()
        let encoder = KabanCoding.makeEncoder()
        for name in names {
            let root = try object(Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name)))
            let given = root["given"] as? [String: Any] ?? [:]
            let cards = try (given["tasks"] as? [[String: Any]] ?? []).map { raw -> TaskCard in
                let date = given["clock"] ?? "2026-10-04T08:00:00.000Z"
                let wire: [String: Any] = [
                    "id": raw["id"] ?? "t", "projectId": raw["projectId"] ?? "p-kaban",
                    "title": "fixture", "stageId": raw["stage"] ?? "backlog",
                    "state": raw["state"] ?? ["status": "queued"], "priority": 0,
                    "attempt": raw["attempt"] ?? 0, "runsSinceHuman": raw["autoRuns"] ?? 0,
                    "bounceByReason": raw["bounces"] ?? [:], "overlapsWith": [],
                    "unusedGitGrants": 0, "suspiciousFiles": raw["suspiciousFiles"] ?? [],
                    "retryAt": raw["retryAt"] ?? NSNull(), "updatedAt": date,
                ]
                return try decoder.decode(TaskCard.self, from: JSONSerialization.data(withJSONObject: wire))
            }
            var projection = BoardProjection(snapshot: Snapshot(seq: 0, projects: [], pipelines: [], tasks: cards))
            var seq: Seq = 0
            var clock = try decoder.decode(Date.self, from: canonical(given["clock"] ?? "2026-10-04T08:00:00.000Z"))
            for (stepIndex, step) in (root["steps"] as? [[String: Any]] ?? []).enumerated() {
                if let advance = step["advance"] as? String { clock.addTimeInterval(try duration(advance)) }
                guard let then = step["then"] as? [String: Any] else { continue }
                for event in then["events"] as? [[String: Any]] ?? [] {
                    guard ["taskCreated", "taskUpdated", "taskEdited"].contains(event["type"] as? String ?? "") else { continue }
                    let journal = try decoder.decode(JournalEvent.self, from: JSONSerialization.data(withJSONObject: event))
                    seq += 1
                    XCTAssertEqual(projection.apply(Fix.envelope(seq, journal)), .applied)
                }
                for (id, expectation) in then["tasks"] as? [String: [String: Any]] ?? [:] {
                    let card = try XCTUnwrap(projection.tasks[TaskID(rawValue: id)], "\(name) step \(stepIndex + 1)")
                    let stored = try object(encoder.encode(card))
                    for (field, expected) in expectation {
                        let key = mapping[field] ?? field
                        XCTAssertTrue(["stageId", "state", "attempt", "runsSinceHuman", "bounceByReason", "retryAt", "suspiciousFiles"].contains(key), "unsupported oracle field \(field)")
                        let actual = stored[key] ?? NSNull()
                        let resolved: Any
                        if field == "retryAt", let relative = expected as? String, relative.hasPrefix("+") {
                            let date = clock.addingTimeInterval(try duration(String(relative.dropFirst())))
                            resolved = try JSONSerialization.jsonObject(with: encoder.encode(date), options: [.fragmentsAllowed])
                        } else { resolved = expected }
                        // Structural JSON equality avoids dictionary order and preserves null semantics.
                        XCTAssertEqual(try canonical(actual), try canonical(resolved), "\(name) step \(stepIndex + 1) \(id).\(field)")
                        assertions += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(assertions, 100, "scenario oracle must exercise substantive expectations")
        print("Team2 scenario then.tasks field assertions: \(assertions)")
    }

    private func duration(_ value: String) throws -> TimeInterval {
        let number = try XCTUnwrap(Double(value.dropLast()))
        let unit = try XCTUnwrap(value.last)
        let multiplier: Double = unit == "m" ? 60 : unit == "h" ? 3600 : 1
        XCTAssertTrue([Character("s"), "m", "h"].contains(unit))
        return number * multiplier
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
}
