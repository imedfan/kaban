import Foundation
import KabanProtocol

/// Compact columns group by meaning, never by a stage ID shared by unrelated pipelines.
public enum BoardKindGroup: String, CaseIterable, Sendable {
    case queue, agent, waitingHuman, merge, terminal
    public var title: String {
        switch self {
        case .queue: "Очередь"
        case .agent: "Работа агентов"
        case .waitingHuman: "Ждут человека"
        case .merge: "Слияние"
        case .terminal: "Завершены"
        }
    }
    public static func group(card: TaskCard, stage: StageSummary) -> Self {
        if card.state.status == .waitingHuman { return .waitingHuman }
        switch stage.kind {
        case .queue: return .queue
        case .agent, .gate: return .agent
        case .human: return .waitingHuman
        case .merge: return .merge
        case .terminal: return .terminal
        }
    }
}

/// Scoped to a project: stage IDs alone do not identify a board column.
public struct BoardStageKey: Hashable, Sendable {
    public let projectID: ProjectID
    public let stageID: StageID
    public init(projectID: ProjectID, stageID: StageID) { self.projectID = projectID; self.stageID = stageID }
}

public struct StageLoadPresentation: Equatable, Sendable {
    public let label: String
    public let exceeded: Bool
    public init(load: StageLoad) {
        label = load.wipLimit.map { "\(load.wipUsed)/\($0)" } ?? "\(load.wipUsed)"
        exceeded = load.wipLimit.map { load.wipUsed > $0 } ?? false
    }
}

public struct CardBadge: Equatable, Sendable {
    public let label: String
    public let symbol: String
    public let help: String
    public init(_ label: String, symbol: String, help: String) { self.label = label; self.symbol = symbol; self.help = help }
}

extension CardPresentation {
    /// Only a report from the current run may appear on a card. An old retained
    /// ephemeral report must not follow the task into another run or stage.
    public static func progress(card: TaskCard, currentRun: RunSummary?, reports: [RunID: RunProgress]) -> RunProgress? {
        guard card.state == .running, let run = currentRun, run.taskId == card.id,
              run.stageId == card.stageId, run.endedAt == nil,
              run.status == .starting || run.status == .running,
              let report = reports[run.id], report.taskId == card.id else { return nil }
        return report
    }
    public static func badges(card: TaskCard, pipeline: PipelineSummary?) -> [CardBadge] {
        var result: [CardBadge] = []
        if card.unusedGitGrants > 0 {
            result.append(.init("Git · \(card.unusedGitGrants)", symbol: "key", help: "Неиспользованные разрешения git: \(card.unusedGitGrants)"))
        }
        for (key, count) in card.bounceByReason.sorted(by: { $0.key < $1.key }) where count > 0 {
            var name = key
            if key == "merge_conflict" { name = "При конфликте" }
            else if let pipeline {
                let matches = pipeline.stages.flatMap { source in
                    pipeline.stages.compactMap { target -> String? in
                        key == "\(source.id.rawValue)_\(target.id.rawValue)" ? source.name + " → " + target.name : nil
                    }
                }
                if matches.count == 1 { name = matches[0] }
            }
            result.append(.init("\(name) · \(count)", symbol: "arrow.uturn.backward", help: "Возвраты: \(name), \(count)"))
        }
        if !card.overlapsWith.isEmpty {
            result.append(.init("Пересечения · \(card.overlapsWith.count)", symbol: "square.on.square", help: "Пересекается с: " + card.overlapsWith.map(\.rawValue).joined(separator: ", ")))
        }
        if let model = card.model {
            result.append(.init(model.rawValue, symbol: "cpu", help: "Модель: \(model.rawValue)"))
        }
        if !card.hasAcceptanceCriteria && card.state.status != .done && card.state.status != .cancelled {
            result.append(.init("Нет критериев", symbol: "checklist", help: "Без критериев приёмки задача не запустится."))
        }
        return result
    }
    public static func retryCountdown(card: TaskCard, now: Date) -> String? {
        guard case .retryWait(let reason) = card.state, reason.chargesAttempt, let retryAt = card.retryAt else { return nil }
        let remaining = max(0, Int(ceil(retryAt.timeIntervalSince(now))))
        if remaining == 0 { return "Ожидает повторного запуска" }
        return "Повтор через \(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }
}


/// Do not infer the exhausted bounce rule by summing card counters: a total
/// limit and its source are not present in the current summary contract.
public struct LimitReasonText: Equatable, Sendable {
    public let title: String
    public let qualifier: String?
    public init(card: TaskCard, pipeline: PipelineSummary?) {
        title = card.state == .waitingHuman(.conflictLimit) ? "Лимит возвратов" : CardPresentation(state: card.state).label
        let stage = pipeline?.stages.first { $0.id == card.stageId }
        if card.state == .waitingHuman(.conflictLimit), stage?.kind == .merge,
           let limit = stage?.onConflict?.limit, let count = card.bounceByReason["merge_conflict"] {
            qualifier = "при конфликте, \(count) из \(limit)"
        } else if card.state == .waitingHuman(.runLimit), let limit = pipeline?.maxRunsPerTask {
            qualifier = "\(card.runsSinceHuman) из \(limit)"
        } else { qualifier = nil }
    }
}
