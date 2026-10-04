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
    /// кроме Backlog → следующая стадия. Столбец `kind == .gate` — запрещённая цель.
    /// Между проектами переносить нельзя.
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
        // TODO(protocol): у StageSummary нет списка гейтов. Запрет «вперёд через стадии
        // с гейтами» опирается на kind == .gate и на общий запрет переноса вперёд.
        // Гейты agent-стадии, которые не отражены отдельной gate-колонкой, не видны.
        if target.kind == .gate {
            return .forbidden(.gateColumn)
        }
        if targetIndex > sourceIndex {
            // TODO(protocol): у TaskCard нет критериев приёмки, поэтому исключение
            // «Backlog → первая стадия, только если критерии есть» проверить нельзя.
            // Разрешаем переход структурно: queue → следующая стадия.
            let source = stages[sourceIndex]
            if source.kind == .queue && targetIndex == sourceIndex + 1 {
                return .allowed(interruptConfirmation: nil)
            }
            return .forbidden(.forwardMove)
        }
        let needsConfirmation = card.state.status == .running || card.state.status == .gating
        return .allowed(interruptConfirmation: needsConfirmation ? interruptConfirmation : nil)
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
