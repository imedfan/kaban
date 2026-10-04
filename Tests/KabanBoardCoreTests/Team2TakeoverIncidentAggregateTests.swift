import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

/// #44: oracle is the daemon's ProjectSummary count, not a count of known details.
final class Team2TakeoverIncidentAggregateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_100_800)
    private let projectID: ProjectID = "aggregate-a"
    private let otherID: ProjectID = "aggregate-b"

    private func project(_ id: ProjectID, count: Int) -> ProjectSummary {
        ProjectSummary(id: id, name: id.rawValue, path: "/fixtures/\(id.rawValue)", mascotSeed: id.rawValue, openIncidentCount: count)
    }
    private func snapshot(_ counts: [Int], seq: Seq = 0) -> Snapshot {
        let summaries = zip([projectID, otherID], counts).map { project($0.0, count: $0.1) }
        return Snapshot(seq: seq, projects: summaries, pipelines: [], tasks: [], openIncidentCount: counts.reduce(0, +))
    }
    private func apply(_ event: JournalEvent, seq: Seq, to board: inout BoardProjection, project: ProjectID? = nil) {
        XCTAssertEqual(board.apply(EventEnvelope(seq: seq, at: now, projectId: project ?? projectID, event: event)), .applied)
    }
    private var opened: Incident {
        Incident(id: "aggregate-incident", projectId: projectID, taskId: "aggregate-task", runId: nil,
                 kind: .refsMoved, rolledBack: [], openedAt: now)
    }
    private func assertCounts(_ board: BoardProjection, a: Int, b: Int) {
        XCTAssertEqual(board.badgeCounts(for: projectID).openIncidents, a)
        XCTAssertEqual(board.badgeCounts(for: otherID).openIncidents, b)
        XCTAssertEqual(board.openIncidentCount, a + b)
    }

    func testProjectUpdateAloneReconcilesGlobalAggregateWithHiddenProject() {
        var board = BoardProjection(snapshot: snapshot([0, 4]))
        apply(.projectUpdated(project(projectID, count: 2)), seq: 1, to: &board)
        assertCounts(board, a: 2, b: 4)
        XCTAssertTrue(board.lanes(orderedBy: []).isEmpty, "BoardSet visibility never changes the aggregate")
    }

    func testOpenedAndProjectSummaryConvergeInEitherTransactionOrder() {
        for summaryFirst in [false, true] {
            var board = BoardProjection(snapshot: snapshot([2, 4]))
            let summary = JournalEvent.projectUpdated(project(projectID, count: 3))
            let detail = JournalEvent.incidentOpened(opened)
            apply(summaryFirst ? summary : detail, seq: 1, to: &board)
            assertCounts(board, a: summaryFirst ? 3 : 2, b: 4)
            apply(summaryFirst ? detail : summary, seq: 2, to: &board)
            assertCounts(board, a: 3, b: 4)
            XCTAssertEqual(board.incidents[opened.id], opened)
            XCTAssertEqual(board.feed.count, 2)
        }
    }

    func testResolvedAndProjectSummaryConvergeForKnownAndSnapshotOnlyIncidents() {
        for knownDetail in [false, true] {
            for summaryFirst in [false, true] {
                var board = BoardProjection(snapshot: snapshot([3, 4]))
                if knownDetail { apply(.incidentOpened(opened), seq: 1, to: &board) }
                let first: Seq = knownDetail ? 2 : 1
                let summary = JournalEvent.projectUpdated(project(projectID, count: 2))
                let resolved = JournalEvent.incidentResolved(IncidentResolved(incidentId: opened.id, by: .human, commandId: nil))
                apply(summaryFirst ? summary : resolved, seq: first, to: &board)
                apply(summaryFirst ? resolved : summary, seq: first + 1, to: &board)
                assertCounts(board, a: 2, b: 4)
                if knownDetail { XCTAssertEqual(board.incidents[opened.id]?.resolvedAt, now) }
                // A duplicate detail with a new sequence is not a second decrement.
                apply(resolved, seq: first + 2, to: &board)
                assertCounts(board, a: 2, b: 4)
            }
        }
    }

    func testSnapshotReplacementProjectAdditionAndRepeatedDeletionRemainConsistent() {
        var board = BoardProjection(snapshot: snapshot([3, 4]))
        apply(.incidentOpened(opened), seq: 1, to: &board)
        board.replace(with: snapshot([1, 2], seq: 10))
        assertCounts(board, a: 1, b: 2)
        XCTAssertTrue(board.incidents.isEmpty)
        apply(.projectRemoved(projectID), seq: 11, to: &board)
        assertCounts(board, a: 0, b: 2)
        apply(.projectRemoved(projectID), seq: 12, to: &board)
        assertCounts(board, a: 0, b: 2)
        apply(.projectAdded(project(projectID, count: 5)), seq: 13, to: &board)
        assertCounts(board, a: 5, b: 2)
    }
}
