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
            label = reason == .wipFull ? "Ждёт места" : (reason == .quotaCm || reason == .quotaOm ? "Ждёт квоту" : "В очереди")
            symbol = "clock"; tone = .queued
        case .running: label = "Работает"; symbol = "play.circle"; tone = .running
        case .gating: label = "Проверяет"; symbol = "checkmark.shield"; tone = .gating
        case .retryWait: label = "Повтор позже"; symbol = "arrow.clockwise"; tone = .retry
        case .waitingHuman(let reason):
            if reason == .review { label = "На ревью"; symbol = "eye"; tone = .review }
            else if reason == .incident { label = "Инцидент"; symbol = "exclamationmark.octagon"; tone = .incident }
            else {
                switch reason {
                case .question: label = "Вопрос к вам"
                case .suspiciousFiles: label = "Подозрительные файлы"
                case .retriesExhausted: label = "Попытки исчерпаны"
                case .bounceLimit: label = "Лимит возвратов"
                case .conflictLimit: label = "Лимит конфликтов"
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
}
