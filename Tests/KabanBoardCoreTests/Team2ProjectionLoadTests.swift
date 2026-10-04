import Foundation
import XCTest
@testable import KabanBoardCore
import KabanProtocol

final class Team2ProjectionLoadTests: XCTestCase {
    func testTenProjectsFiveHundredTasksAndTwentyThousandEventsFiveTimes() {
        let projects = (0..<10).map { Fix.project(ProjectID(rawValue: "load-\($0)")) }
        let initial = projects.flatMap { project in
            (0..<500).map { Fix.card("\(project.id.rawValue)-\($0)", project: project.id) }
        }
        let snapshot = Fix.snapshot(seq: 0, tasks: initial, projects: projects,
            pipelines: projects.map { Fix.pipeline(project: $0.id) })
        var rng = LoadRandom(seed: 0x4B4142414E)
        var events: [EventEnvelope] = []
        var latest: [TaskID: (title: String, state: TaskState, stage: StageID)] = [:]
        var names: [ProjectID: String] = [:]
        var created = 0
        for index in 1...20_000 {
            let project = projects[rng.next(10)]
            let kind = rng.next(10)
            let event: JournalEvent
            if kind == 0 {
                var updated = project
                updated.name = "renamed-\(index)"
                names[project.id] = updated.name
                event = .projectUpdated(updated)
            } else {
                let id: String
                if kind == 1 { id = "created-\(index)"; created += 1 }
                else { id = "\(project.id.rawValue)-\(rng.next(500))" }
                let state: TaskState = rng.next(2) == 0 ? .running : .waitingHuman(.question)
                let stage: String = rng.next(2) == 0 ? "dev" : "test"
                let title = "event-\(index)"
                let card = Fix.card(id, stage: stage, state: state, title: title, project: project.id)
                latest[card.id] = (title, state, card.stageId)
                event = kind == 1 ? .taskCreated(card) : .taskUpdated(card)
            }
            events.append(Fix.envelope(Seq(index), event, projectId: project.id))
        }
        var times: [Double] = []
        for run in 1...5 {
            var projection = BoardProjection(snapshot: snapshot)
            var peak = projection.tasks.count
            let start = ContinuousClock.now
            for event in events {
                if projection.apply(event) != .applied { XCTFail("run \(run), seq \(event.seq)") }
                peak = max(peak, projection.tasks.count)
            }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            times.append(seconds)
            XCTAssertEqual(projection.tasks.count, 5_000 + created)
            XCTAssertEqual(peak, 5_000 + created)
            XCTAssertEqual(Set(projection.taskOrder).count, projection.tasks.count)
            XCTAssertEqual(projection.taskOrder.count, projection.tasks.count)
            XCTAssertEqual(projection.stateSeq, 20_000)
            XCTAssertFalse(projection.needsResync)
            // Check every final mutation, not only a few sampled cards.
            for (id, expected) in latest {
                XCTAssertEqual(projection.tasks[id]?.title, expected.title)
                XCTAssertEqual(projection.tasks[id]?.state, expected.state)
                XCTAssertEqual(projection.tasks[id]?.stageId, expected.stage)
            }
            for (id, name) in names { XCTAssertEqual(projection.projects[id]?.name, name) }
            XCTAssertEqual(projection.lanes().flatMap(\.columns).flatMap(\.taskIds).count, projection.tasks.count)
            print("Team2 load run=\(run) events=20000 initial=5000 final=\(projection.tasks.count) peakCards=\(peak) applySeconds=\(seconds)")
        }
        print("Team2 load meanSeconds=\(times.reduce(0, +) / 5) worstSeconds=\(times.max()!)")
        // No elapsed-time assertion: host/CI speed is diagnostic, correctness is mandatory.
    }
}

private struct LoadRandom {
    var seed: UInt64
    mutating func next(_ bound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 32) % UInt64(bound))
    }
}
