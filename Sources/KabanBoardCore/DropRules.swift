import Foundation
import KabanProtocol

/// Куда можно бросить карточку. Только данные: команду `moveTask` модуль не шлёт.
public enum DropDecision: Equatable, Sendable {
    /// `interruptConfirmation` — текст подтверждения, если перенос прервёт текущий run.
    case allowed(interruptConfirmation: String?)
    case forbidden(DropForbidReason)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

public enum DropForbidReason: String, Equatable, Sendable {
    case sameColumn
    case crossProject
    case gateColumn
    case forwardMove
    case unknownStage

    public var text: String {
        switch self {
        case .sameColumn: "Задача уже в этом столбце"
        case .crossProject: "Нельзя переносить задачу в другой проект"
        case .gateColumn: "В столбец гейта нельзя перетащить задачу"
        case .forwardMove: "Перетаскивание вперёд запрещено"
        case .unknownStage: "Стадия не найдена в пайплайне"
        }
    }
}

public enum DropRules {
    public static let interruptConfirmation = "Прервать текущий запуск? Попытка не спишется"

    /// Правила UC-11: назад можно (с подтверждением, если run идёт), вперёд нельзя,
    /// кроме Backlog → следующая стадия при `hasAcceptanceCriteria`. Столбец `kind == .gate`
    /// — запрещённая цель. Между проектами переносить нельзя.
    public static func evaluate(card: TaskCard, target: StageSummary, in pipeline: PipelineSummary) -> DropDecision {
        if pipeline.projectId != card.projectId {
            return .forbidden(.crossProject)
        }
        let stages = orderedStages(pipeline)
        guard let sourceIndex = stages.firstIndex(where: { $0.id == card.stageId }),
              let targetIndex = stages.firstIndex(where: { $0.id == target.id })
        else {
            return .forbidden(.unknownStage)
        }
        if stages[targetIndex].id != target.id || stages[targetIndex].kind != target.kind {
            return .forbidden(.unknownStage)
        }
        if sourceIndex == targetIndex {
            return .forbidden(.sameColumn)
        }
        if target.kind == .gate {
            return .forbidden(.gateColumn)
        }
        if targetIndex > sourceIndex {
            // Вперёд нельзя. Исключение — из `queue` в соседнюю стадию и только если
            // у карточки есть критерии приёмки. Стадия между источником и целью
            // с `kind == .gate` или с непустым `gates` тоже закрывает переход:
            // гейты agent-стадии без своей колонки видны так же, как столбец гейта.
            // Гейты самой цели входу в неё не мешают.
            if crossesStagesWithGates(from: sourceIndex, to: targetIndex, stages: stages) {
                return .forbidden(.forwardMove)
            }
            let source = stages[sourceIndex]
            if source.kind == .queue && targetIndex == sourceIndex + 1 && card.hasAcceptanceCriteria {
                return .allowed(interruptConfirmation: nil)
            }
            return .forbidden(.forwardMove)
        }
        let needsConfirmation = card.state.status == .running || card.state.status == .gating
        return .allowed(interruptConfirmation: needsConfirmation ? interruptConfirmation : nil)
    }

    /// Есть ли между стадиями барьер: столбец `gate` или стадия с непустым `gates`.
    static func crossesStagesWithGates(from sourceIndex: Int, to targetIndex: Int, stages: [StageSummary]) -> Bool {
        guard targetIndex > sourceIndex + 1 else { return false }
        return stages[(sourceIndex + 1)..<targetIndex].contains { $0.kind == .gate || !$0.gates.isEmpty }
    }

    static func orderedStages(_ pipeline: PipelineSummary) -> [StageSummary] {
        pipeline.stages.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.display.order != rhs.element.display.order {
                    return lhs.element.display.order < rhs.element.display.order
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
