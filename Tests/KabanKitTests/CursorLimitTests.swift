import XCTest
import KabanProtocol
@testable import KabanKit

final class CursorLimitTests: XCTestCase {
    func testClassifierKeepsUnknownTextAndDoesNotTreatNilQuotaAsFree() {
        XCTAssertNil(CursorLimitClassifier.classify("  ", pool: .om))
        XCTAssertEqual(CursorLimitClassifier.classify("usage limit reached", pool: .om), .usageExhausted(.om))
        XCTAssertEqual(CursorLimitClassifier.classify("spendLimitHit", pool: nil), .usageExhausted(nil))
        XCTAssertEqual(CursorLimitClassifier.classify("resource_exhausted", pool: .cm), .modelUnavailable)
        XCTAssertEqual(CursorLimitClassifier.classify("not available in the slow pool", pool: .cm), .modelUnavailable)
        XCTAssertEqual(CursorLimitClassifier.classify("Too many requests", pool: .cm), .rateLimit)
        XCTAssertEqual(CursorLimitClassifier.classify("authentication failed", pool: .cm), .runnerAuth)
        XCTAssertEqual(CursorLimitClassifier.classify("boom", pool: .om), .unknown)
        XCTAssertEqual(CursorLimitClassifier.redact("boom token=abc"), "Неклассифицированная ошибка.")
        XCTAssertEqual(CursorLimitClassifier.cooldown(after: nil).seconds, 15 * 60)
        XCTAssertEqual(CursorLimitClassifier.cooldown(after: 1).seconds, 30 * 60)
        XCTAssertEqual(CursorLimitClassifier.cooldown(after: 2).seconds, 60 * 60)
        XCTAssertEqual(CursorLimitClassifier.cooldown(after: 3).step, 3)
        let quota = QuotaState(cm: nil, om: 40, billingCycleEnd: nil, fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(quota.freePercent(.cm))
        XCTAssertNotEqual(quota.freePercent(.cm), 100)
        XCTAssertEqual(quota.freePercent(.om), 60)
        XCTAssertEqual(CursorLimitClassifier.resetDate(in: "resets 2026-10-06T12:00:00Z"), Date(timeIntervalSince1970: 1_791_288_000))
    }
}
