import KabanProtocol

/// Semantic presentation independent of SwiftUI; colours map to the approved tokens.
public struct CardPresentation: Equatable, Sendable {
    public enum Tone: String, Sendable { case queued, running, gating, retry, waiting, review, paused, blocked, incident, done, cancelled }
    public let label: String
    public let symbol: String
    public let tone: Tone
    public init(state: TaskState) {
        switch state {
        case .queued(let reason):
            switch reason {
            case .wipFull: label = "Ждёт места"
            case .quotaCm: label = "Ждёт квоту Cm"
            case .quotaOm: label = "Ждёт квоту Om"
            case .modelFlag: label = "Ждёт модель"
            case nil: label = "В очереди"
            }
            symbol = "clock"; tone = .queued
        case .running: label = "Работает"; symbol = "play.circle"; tone = .running
        case .gating: label = "Проверяет"; symbol = "checkmark.shield"; tone = .gating
        case .retryWait(let reason):
            switch reason {
            case .crash: label = "Повтор после сбоя"
            case .stallTimeout: label = "Нет активности"
            case .wallTimeout: label = "Время запуска истекло"
            case .noFinalCall: label = "Нет итогового результата"
            case .gateFailed: label = "Гейты не прошли"
            case .rateLimit: label = "После лимита Cursor"
            case .runnerAuth: label = "Ждёт входа в Cursor"
            case .daemonRestart: label = "Повтор после перезапуска"
            case .silentExit: label = "Проверяем выход CLI"
            case .readonlyViolation: label = "Нарушен режим чтения"
            }
            symbol = "arrow.clockwise"; tone = .retry
        case .waitingHuman(let reason):
            if reason == .review { label = "На ревью"; symbol = "eye"; tone = .review }
            else if reason == .incident { label = "Инцидент"; symbol = "exclamationmark.octagon"; tone = .incident }
            else {
                switch reason {
                case .question: label = "Вопрос к вам"
                case .suspiciousFiles: label = "Подозрительные файлы"
                case .retriesExhausted: label = "Попытки исчерпаны"
                case .bounceLimit: label = "Лимит возвратов"
                case .conflictLimit: label = "Лимит возвратов при конфликте"
                case .runLimit: label = "Лимит запусков на задачу"
                case .modelSubstituted: label = "Подмена модели"
                case .gitDenials: label = "Запрет git"
                case .invalidResult: label = "Некорректный результат"
                case .review, .incident: label = "Ждёт вас"
                }
                symbol = reason == .suspiciousFiles ? "exclamationmark.shield" : "person.crop.circle.badge.exclamationmark"
                tone = .waiting
            }
        case .paused: label = "Пауза"; symbol = "pause.circle"; tone = .paused
        case .blocked: label = "Основная ветка изменена"; symbol = "lock"; tone = .blocked
        case .done: label = "Готово"; symbol = "checkmark.circle"; tone = .done
        case .cancelled: label = "Отменено"; symbol = "xmark.circle"; tone = .cancelled
        }
    }
    public init(card: TaskCard, stage: StageSummary? = nil, hasCurrentProgress: Bool = false) {
        let base = CardPresentation(state: card.state)
        symbol = base.symbol; tone = base.tone
        if card.state == .running {
            label = hasCurrentProgress ? "Получен прогресс" : "Запуск зарезервирован"
        } else if card.state == .gating && stage?.kind == .merge {
            label = "Rebase и гейты"
        } else {
            label = base.label
        }
    }

}
