import Foundation
import XCTest
@testable import KabanProtocol

final class WIPRestoreContractTests: XCTestCase {
    func testLegacyUnknownEmptyAndEveryOutcomeRoundTrip() throws {
        let encoder = KabanCoding.makeEncoder(), decoder = KabanCoding.makeDecoder()
        var detail = Samples.taskDetail
        let legacy = try encoder.encode(detail)
        XCTAssertNil(try decoder.decode(TaskDetail.self, from: legacy).wipRestoreOperations)
        XCTAssertNil((try JSONSerialization.jsonObject(with: legacy) as? [String: Any])?["wipRestoreOperations"])
        detail.wipRestoreOperations = []
        XCTAssertEqual(try decoder.decode(TaskDetail.self, from: encoder.encode(detail)).wipRestoreOperations, [])
        for status in [WIPRestoreOperation.Status.pending, .succeeded, .failed, .superseded] {
            detail.wipRestoreOperations = [.init(commandId: UUID(), runId: "r", wipRef: "refs/kaban/wip/r", status: status, completedSeq: status == .succeeded || status == .failed ? 12 : nil, message: status == .failed ? "Git refused" : nil)]
            XCTAssertEqual(try decoder.decode(TaskDetail.self, from: encoder.encode(detail)), detail)
        }
    }
    func testNewFieldDoesNotMakeExistingRequiredFieldsOptional() throws {
        let decoder = KabanCoding.makeDecoder()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: KabanCoding.makeEncoder().encode(Samples.taskDetail)) as? [String: Any])
        for key in ["seq", "task", "feed", "runs", "humanRequests", "suspiciousFiles", "acceptedFiles"] {
            var json = original; json["wipRestoreOperations"] = []; json.removeValue(forKey: key)
            XCTAssertThrowsError(try decoder.decode(TaskDetail.self, from: JSONSerialization.data(withJSONObject: json)), key)
        }
        var malformed = original; malformed["wipRestoreOperations"] = "pending"
        XCTAssertThrowsError(try decoder.decode(TaskDetail.self, from: JSONSerialization.data(withJSONObject: malformed)))
    }
}
