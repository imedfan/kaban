import Foundation
import XCTest
import KabanProtocol

final class SchedulerSettingsChangeTests: XCTestCase {
    func testLegacySettingsChangeKeepsGoldenShapeAndUnknownFlags() throws {
        let legacy = Data(#"{"key":"paused","value":"true"}"#.utf8)
        let change = try KabanCoding.makeDecoder().decode(SettingsChange.self, from: legacy)
        XCTAssertNil(change.schedulerFlags); XCTAssertNil(change.settings)
        let encoded = try KabanCoding.makeEncoder().encode(change)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: legacy) as? NSDictionary)
    }

    func testAuthoritativeFlagsAndExplicitClearSurviveJournalRoundTrip() throws {
        for flags: [SchedulerFlag] in [[], [.macPaused, .projectPaused("p"), .intakePaused("q")]] {
            let envelope = EventEnvelope(seq: 9, at: Date(timeIntervalSince1970: 123), projectId: nil, commandId: UUID(),
                                         event: .settingsChanged(SettingsChange(key: "scheduler", value: "updated", schedulerFlags: flags)))
            let encoded = try KabanCoding.makeEncoder().encode(envelope)
            XCTAssertEqual(try KabanCoding.makeDecoder().decode(EventEnvelope.self, from: encoded), envelope)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let event = try XCTUnwrap(json["event"] as? [String: Any])
            let data = try XCTUnwrap(event["data"] as? [String: Any])
            XCTAssertNotNil(data["schedulerFlags"], "Empty must clear flags instead of encoding unknown")
        }
    }

    func testMalformedKnownFlagsAreRejectedAndNullRemainsUnknown() throws {
        let decoder = KabanCoding.makeDecoder()
        XCTAssertThrowsError(try decoder.decode(SettingsChange.self, from: Data(#"{"key":"scheduler","value":"updated","schedulerFlags":42}"#.utf8)))
        XCTAssertNil(try decoder.decode(SettingsChange.self, from: Data(#"{"key":"scheduler","value":"updated","schedulerFlags":null}"#.utf8)).schedulerFlags)
        XCTAssertThrowsError(try decoder.decode(SettingsChange.self, from: Data(#"{"value":"updated","schedulerFlags":[]}"#.utf8)), "Legacy key remains required")
    }
}
