import Foundation
import XCTest
@testable import KabanBoardCore
import KabanProtocol

final class ScenarioReplayTests: XCTestCase {
    private let decoder = KabanCoding.makeDecoder()

    func testAllM1ScenariosReplayInAnyEventOrder() throws {
        let directory = try scenariosDirectory()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(names.count, 33)
        var skipped: [String] = []
        for name in names {
            for order in ReplayOrder.allCases {
                let run = try replay(directory: directory, name: name, order: order)
                if order == .written { skipped.append(contentsOf: run.skipped) }
                XCTAssertFalse(run.steps.isEmpty, name)
            }
        }
        if !skipped.isEmpty {
            print("KabanBoardCore: пропущены предметные события, которые не декодируются в JournalEvent (\(skipped.count)):")
            for line in skipped.sorted() {
                print("  \(line)")
            }
        }
    }

    func testSUSP01FoundFilesStayOnTheCardUntilAccepted() throws {
        let run = try replay(name: "M1-SUSP-01.json")
        XCTAssertEqual(run.steps.count, 2)
        let found = try XCTUnwrap(run.steps[0].tasks["t-1"])
        XCTAssertEqual(found.state, .waitingHuman(.suspiciousFiles))
        XCTAssertEqual(found.attempt, 1)
        XCTAssertEqual(found.suspiciousFiles.map(\.path), [".env.local"])
        XCTAssertFalse(found.suspiciousFiles.contains { $0.path == ".env.example" })
        let accepted = try XCTUnwrap(run.steps[1].tasks["t-1"])
        XCTAssertEqual(accepted.stageId.rawValue, "test")
        XCTAssertEqual(accepted.state, .queued(nil))
        XCTAssertEqual(accepted.suspiciousFiles, [])
        XCTAssertEqual(accepted.runsSinceHuman, 0)
        XCTAssertFalse(run.steps[1].isSent("t-1"))
    }

    func testSUSP03StaleCommandDoesNotChangeTheCard() throws {
        let run = try replay(name: "M1-SUSP-03.json")
        let card = try XCTUnwrap(run.steps[0].tasks["t-1"])
        XCTAssertEqual(card.state, .waitingHuman(.suspiciousFiles))
        XCTAssertEqual(card.stageId.rawValue, "dev")
        XCTAssertEqual(card.suspiciousFiles.map(\.blob), ["ffff01"])
        XCTAssertFalse(run.steps[0].isSent("t-1"))
        XCTAssertTrue(run.steps[0].feed.isEmpty)
    }

    func testSUSP04AnswerHumanDoesNotAcceptTheSet() throws {
        let run = try replay(name: "M1-SUSP-04.json")
        XCTAssertEqual(run.steps.count, 3)
        let queued = try XCTUnwrap(run.steps[0].tasks["t-1"])
        XCTAssertEqual(queued.state, .queued(nil))
        XCTAssertEqual(queued.stageId.rawValue, "dev")
        XCTAssertEqual(queued.suspiciousFiles.map(\.path), [".env.local"])
        XCTAssertFalse(run.steps[0].isSent("t-1"))
        XCTAssertEqual(run.steps[1].tasks["t-1"]?.state, .running)
        let again = try XCTUnwrap(run.steps[2].tasks["t-1"])
        XCTAssertEqual(again.state, .waitingHuman(.suspiciousFiles))
        XCTAssertEqual(again.suspiciousFiles.map(\.path), [".env.local"])
    }

    func testSUSP05RetryClearsFilesViaTaskUpdated() throws {
        let run = try replay(name: "M1-SUSP-05.json")
        let card = try XCTUnwrap(run.steps[0].tasks["t-1"])
        XCTAssertEqual(card.state, .queued(nil))
        XCTAssertEqual(card.stageId.rawValue, "dev")
        XCTAssertEqual(card.suspiciousFiles, [])
        XCTAssertFalse(run.steps[0].isSent("t-1"))
    }

    private func replay(name: String, order: ReplayOrder = .written) throws -> ScenarioRun {
        try replay(directory: scenariosDirectory(), name: name, order: order)
    }

    private func replay(directory: String, name: String, order: ReplayOrder) throws -> ScenarioRun {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let given = root["given"] as? [String: Any] ?? [:]
        let clock = try date(given["clock"] as? String)
        let givenTasks = given["tasks"] as? [[String: Any]] ?? []
        let cards = try givenTasks.map { try initialCard($0, clock: clock) }
        var seen = Set<ProjectID>()
        let projects = cards.map(\.projectId).filter { seen.insert($0).inserted }.map {
            ProjectSummary(id: $0, name: $0.rawValue, path: "/", mascotSeed: $0.rawValue)
        }
        let snapshot = Snapshot(seq: 0, projects: projects.isEmpty ? [Fix.project()] : projects, pipelines: [], tasks: cards)
        var projection = BoardProjection(snapshot: snapshot)
        var seq = snapshot.seq
        var skipped: [String] = []
        var steps: [BoardProjection] = []
        let rawSteps = root["steps"] as? [[String: Any]] ?? []
        for (index, step) in rawSteps.enumerated() {
            guard let then = step["then"] as? [String: Any] else { continue }
            let command = commandRef(step)
            if let command, let taskId = command.taskId {
                projection.markSent(commandId: command.id, taskId: taskId, at: clock)
            }
            if then["commandError"] != nil {
                let events = then["events"] as? [Any] ?? []
                XCTAssertEqual(events.count, 0, "\(name) шаг \(index): на commandError событий нет")
                if let command {
                    projection.noteCommandError(command.id)
                    if let taskId = command.taskId {
                        XCTAssertFalse(projection.isSent(taskId), "\(name) шаг \(index)")
                    }
                }
                if let tasks = then["tasks"] as? [String: [String: Any]] {
                    try assertPartial(tasks, projection: projection, file: name, step: index)
                }
                steps.append(projection)
                continue
            }
            let events = then["events"] as? [[String: Any]] ?? []
            let prepared = try prepare(events, file: name, skipped: &skipped)
            for event in ordered(prepared, order) {
                seq += 1
                let result = projection.apply(EventEnvelope(
                    seq: seq, at: clock, projectId: nil, commandId: event.commandId, event: event.event
                ))
                XCTAssertTrue(result == .applied || result == .ignored, "\(name) шаг \(index) seq \(seq): \(result)")
            }
            var lastCard: [TaskID: Prepared] = [:]
            for event in prepared where event.kind == .card {
                if let card = event.card { lastCard[card.id] = event }
            }
            for (taskId, event) in lastCard {
                let stored = try XCTUnwrap(projection.tasks[taskId], "\(name) шаг \(index) \(taskId)")
                let expected = try XCTUnwrap(event.card)
                XCTAssertEqual(stored, expected, "\(name) шаг \(index) \(taskId): карточка заменяется целиком, порядок \(order)")
                for field in Set(event.check + ["id"]) {
                    try assertField(field, stored: stored, expected: expected, file: name, step: index)
                }
            }
            if let command, let taskId = command.taskId,
               prepared.contains(where: { $0.commandId == command.id && $0.kind == .card }) {
                XCTAssertFalse(projection.isSent(taskId), "\(name) шаг \(index): taskUpdated снимает «отправлено»")
            }
            steps.append(projection)
        }
        return ScenarioRun(steps: steps, skipped: skipped)
    }

    private func prepare(_ events: [[String: Any]], file: String, skipped: inout [String]) throws -> [Prepared] {
        var prepared: [Prepared] = []
        for event in events {
            let type = event["type"] as? String ?? ""
            let commandId = uuid(event["commandId"])
            if type == "taskCreated" || type == "taskUpdated" || type == "taskEdited" {
                let card = try decoder.decode(TaskCard.self, from: try jsonData(event["data"] as Any))
                let journal: JournalEvent
                switch type {
                case "taskCreated": journal = .taskCreated(card)
                case "taskEdited": journal = .taskEdited(card)
                default: journal = .taskUpdated(card)
                }
                let check = event["check"] as? [String] ?? []
                prepared.append(Prepared(kind: .card, event: journal, commandId: commandId, check: check, card: card))
                continue
            }
            let payload: [String: Any] = ["type": type, "data": event["data"] ?? [:]]
            do {
                let journal = try decoder.decode(JournalEvent.self, from: try jsonData(payload))
                if case .unknown = journal {
                    skipped.append("\(file) \(type): unknown")
                    continue
                }
                prepared.append(Prepared(kind: .domain, event: journal, commandId: commandId, check: [], card: nil))
            } catch {
                skipped.append("\(file) \(type): \(error)")
            }
        }
        return prepared
    }

    private func ordered(_ events: [Prepared], _ order: ReplayOrder) -> [Prepared] {
        switch order {
        case .written: events
        case .domainFirst: events.filter { $0.kind == .domain } + events.filter { $0.kind == .card }
        case .cardsFirst: events.filter { $0.kind == .card } + events.filter { $0.kind == .domain }
        }
    }

    private func assertField(_ field: String, stored: TaskCard, expected: TaskCard, file: String, step: Int) throws {
        let where_ = "\(file) шаг \(step) поле \(field)"
        switch field {
        case "id": XCTAssertEqual(stored.id, expected.id, where_)
        case "projectId": XCTAssertEqual(stored.projectId, expected.projectId, where_)
        case "title": XCTAssertEqual(stored.title, expected.title, where_)
        case "stageId": XCTAssertEqual(stored.stageId, expected.stageId, where_)
        case "state": XCTAssertEqual(stored.state, expected.state, where_)
        case "priority": XCTAssertEqual(stored.priority, expected.priority, where_)
        case "branch": XCTAssertEqual(stored.branch, expected.branch, where_)
        case "attempt": XCTAssertEqual(stored.attempt, expected.attempt, where_)
        case "maxAttempts": XCTAssertEqual(stored.maxAttempts, expected.maxAttempts, where_)
        case "runsSinceHuman": XCTAssertEqual(stored.runsSinceHuman, expected.runsSinceHuman, where_)
        case "bounceByReason": XCTAssertEqual(stored.bounceByReason, expected.bounceByReason, where_)
        case "overlapsWith": XCTAssertEqual(stored.overlapsWith, expected.overlapsWith, where_)
        case "unusedGitGrants": XCTAssertEqual(stored.unusedGitGrants, expected.unusedGitGrants, where_)
        case "model": XCTAssertEqual(stored.model, expected.model, where_)
        case "retryAt": XCTAssertEqual(stored.retryAt, expected.retryAt, where_)
        case "suspiciousFiles": XCTAssertEqual(stored.suspiciousFiles, expected.suspiciousFiles, where_)
        case "updatedAt": XCTAssertEqual(stored.updatedAt, expected.updatedAt, where_)
        default: XCTFail("\(where_): неизвестное поле check")
        }
    }

    private func assertPartial(_ tasks: [String: [String: Any]], projection: BoardProjection, file: String, step: Int) throws {
        for (id, expected) in tasks {
            let card = try XCTUnwrap(projection.tasks[TaskID(rawValue: id)], "\(file) шаг \(step)")
            if let stage = expected["stage"] as? String {
                XCTAssertEqual(card.stageId.rawValue, stage, file)
            }
            if let state = expected["state"] {
                XCTAssertEqual(card.state, try decoder.decode(TaskState.self, from: try jsonData(state)), file)
            }
            if let attempt = int(expected["attempt"]) {
                XCTAssertEqual(card.attempt, attempt, file)
            }
            if let runs = int(expected["autoRuns"]) {
                XCTAssertEqual(card.runsSinceHuman, runs, file)
            }
            if let files = expected["suspiciousFiles"], !(files is NSNull) {
                XCTAssertEqual(card.suspiciousFiles, try decoder.decode([SuspiciousFile].self, from: try jsonData(files)), file)
            }
        }
    }

    private func initialCard(_ object: [String: Any], clock: Date) throws -> TaskCard {
        let id = object["id"] as? String ?? "t"
        let state = try decoder.decode(TaskState.self, from: try jsonData(object["state"] ?? ["status": "queued"]))
        var files: [SuspiciousFile] = []
        if let raw = object["suspiciousFiles"], !(raw is NSNull) {
            files = try decoder.decode([SuspiciousFile].self, from: try jsonData(raw))
        }
        var bounce: [String: Int] = [:]
        if let raw = object["bounces"] as? [String: Any] {
            for (key, value) in raw { bounce[key] = int(value) ?? 0 }
        }
        var retryAt: Date?
        if let raw = object["retryAt"] as? String {
            retryAt = try date(raw)
        }
        return TaskCard(
            id: TaskID(rawValue: id),
            projectId: ProjectID(rawValue: object["projectId"] as? String ?? "p-kaban"),
            title: "Задача \(id)",
            stageId: StageID(rawValue: object["stage"] as? String ?? "backlog"),
            state: state,
            branch: "kaban/\(id)",
            attempt: int(object["attempt"]) ?? 0,
            maxAttempts: 3,
            runsSinceHuman: int(object["autoRuns"]) ?? 0,
            bounceByReason: bounce,
            model: (object["model"] as? String).map { ModelID(rawValue: $0) },
            retryAt: retryAt,
            suspiciousFiles: files,
            updatedAt: clock
        )
    }

    private func commandRef(_ step: [String: Any]) -> CommandRef? {
        guard let command = step["command"] as? [String: Any],
              let id = uuid(command["commandId"]),
              let body = command["command"] as? [String: Any] else { return nil }
        let taskId = body.values.compactMap { ($0 as? [String: Any])?["taskId"] as? String }.first
        return CommandRef(id: id, taskId: taskId.map { TaskID(rawValue: $0) })
    }

    private func date(_ string: String?) throws -> Date {
        let raw = string ?? "2026-10-04T08:00:00.000Z"
        return try decoder.decode(Date.self, from: Data("\"\(raw)\"".utf8))
    }

    private func jsonData(_ object: Any) throws -> Data {
        if object is NSNull { return Data("null".utf8) }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func int(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        return nil
    }

    private func uuid(_ any: Any?) -> CommandID? {
        guard let string = any as? String else { return nil }
        return UUID(uuidString: string)
    }

    private func scenariosDirectory() throws -> String {
        if let env = ProcessInfo.processInfo.environment["KABAN_SCENARIOS"], !env.isEmpty { return env }
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent("Scenarios").appendingPathComponent("M1")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        XCTFail("Нет Scenarios/M1 и не задан KABAN_SCENARIOS")
        struct MissingScenarios: Error {}
        throw MissingScenarios()
    }
}

private struct ScenarioRun {
    var steps: [BoardProjection]
    var skipped: [String]
}

private struct Prepared {
    enum Kind { case card, domain }
    var kind: Kind
    var event: JournalEvent
    var commandId: CommandID?
    var check: [String]
    var card: TaskCard?
}

private struct CommandRef {
    var id: CommandID
    var taskId: TaskID?
}

private enum ReplayOrder: CaseIterable {
    case written, domainFirst, cardsFirst
}
