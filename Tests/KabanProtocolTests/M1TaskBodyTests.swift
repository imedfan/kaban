import Foundation
import XCTest
@testable import KabanProtocol

final class M1TaskBodyTests: XCTestCase {
    private let encoder = KabanCoding.makeEncoder()
    private let decoder = KabanCoding.makeDecoder()

    func testLegacyShapeOmitsUnknownBodyAndDecodesUnknown() throws {
        let data = try encoder.encode(Samples.taskDetail)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["body"])
        XCTAssertNil(try decoder.decode(TaskDetail.self, from: data).body)
        var explicitNull = json
        explicitNull["body"] = NSNull()
        XCTAssertNil(try decoder.decode(TaskDetail.self, from: JSONSerialization.data(withJSONObject: explicitNull)).body)
    }

    func testMarkdownAndKnownEmptyBodyRoundTrip() throws {
        for body in ["", "# Task\n\nImplement it.\n\n## Acceptance criteria\n- Test passes.\n"] {
            var detail = Samples.taskDetail
            detail.body = body
            let data = try encoder.encode(detail)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["body"] as? String, body)
            XCTAssertEqual(try decoder.decode(TaskDetail.self, from: data), detail)
        }
    }

    func testKnownBodyRejectsWrongTypesAndKeepsRequiredArrays() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(Samples.taskDetail)) as? [String: Any])
        for malformed in [42 as Any, true as Any, ["text": "task"] as Any, ["task"] as Any] {
            var json = original
            json["body"] = malformed
            XCTAssertThrowsError(try decoder.decode(TaskDetail.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        for key in ["humanRequests", "suspiciousFiles", "acceptedFiles"] {
            var json = original
            json["body"] = "known"
            json.removeValue(forKey: key)
            XCTAssertThrowsError(try decoder.decode(TaskDetail.self, from: JSONSerialization.data(withJSONObject: json)), key)
        }
    }
}
