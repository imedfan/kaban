import Foundation
import Observation
import KabanProtocol

@MainActor @Observable public final class MacSettingsStore {
    public enum Section: String, Codable, Sendable { case ceiling, quota }
    private struct Draft: Codable {
        var baseline: GlobalSettings
        var ceiling: String
        var options: QuotaOptions
        var interval: String
        var commandID: CommandID?
        var handledID: CommandID?
    }
    public let session: BoardSession
    private let storage: any KeyValueStoring
    private let key: String
    private var draft: Draft?
    private var handledID: CommandID?
    public private(set) var error: String?
    public private(set) var section: Section?
    public var settings: GlobalSettings? { session.projection?.settings }
    public var ceiling: String { draft?.ceiling ?? "" }
    public var options: QuotaOptions? { draft?.options }
    public var interval: String { draft?.interval ?? "" }
    public var commandID: CommandID? { draft?.commandID }
    public var pending: Bool { session.pending(in: .global) != nil }
    public var receipt: ClientCommandJournal.Record? {
        _ = session.pendingRecords
        return session.journal?.records.first { $0.envelope.commandId == commandID }
    }
    public init(session: BoardSession, storage: any KeyValueStoring, key: String) {
        self.session = session; self.storage = storage; self.key = key
        draft = storage.data(forKey: key).flatMap { try? KabanCoding.makeDecoder().decode(Draft.self, from: $0) }
        handledID = draft?.handledID
    }
    public func begin() {
        guard draft == nil, let settings else { return }
        draft = .init(baseline: settings, ceiling: String(settings.maxConcurrentRuns), options: settings.quotaOptions,
                      interval: String(settings.quotaOptions.pollInterval))
        save()
    }
    public func stale(_ section: Section) -> Bool {
        guard let draft, let settings else { return true }
        return section == .ceiling ? draft.baseline.maxConcurrentRuns != settings.maxConcurrentRuns
            : draft.baseline.quotaOptions != settings.quotaOptions
    }
    public func useCurrent() {
        guard !pending, let settings else { return }
        draft?.baseline = settings; error = nil; save()
    }
    public func reset() {
        guard !pending else { return }; draft = nil; error = nil; handledID = nil; begin()
    }
    public func editCeiling(_ value: String) { guard !pending else { return }; draft?.ceiling = value; section = .ceiling; error = nil; save() }
    public func editInterval(_ value: String) { guard !pending else { return }; draft?.interval = value; section = .quota; error = nil; save() }
    public func editOptions(_ value: QuotaOptions) { guard !pending else { return }; draft?.options = value; section = .quota; error = nil; save() }
    private func command(_ section: Section) -> Command? {
        guard let draft else { return nil }
        switch section {
        case .ceiling:
            guard let count = Int(draft.ceiling), count > 0 else { return nil }
            return .setMaxConcurrentRuns(count: count)
        case .quota:
            guard let interval = Int(draft.interval), interval > 0,
                  draft.options.thresholdCm.isFinite, draft.options.thresholdOm.isFinite,
                  (0...100).contains(draft.options.thresholdCm), (0...100).contains(draft.options.thresholdOm),
                  !draft.options.enabled || draft.options.consent else { return nil }
            var options = draft.options; options.pollInterval = interval
            return .setQuotaOptions(options: options)
        }
    }
    public func canSubmit(_ section: Section) -> Bool {
        guard !pending, !stale(section), let command = command(section), session.can(command) else { return false }
        switch command {
        case .setMaxConcurrentRuns(let count): return count != settings?.maxConcurrentRuns
        case .setQuotaOptions(let options): return options != settings?.quotaOptions
        default: return false
        }
    }
    @discardableResult public func submit(_ section: Section) async -> Bool {
        guard canSubmit(section), let command = command(section) else { return false }
        let envelope = CommandEnvelope(command: command)
        draft?.commandID = envelope.commandId; handledID = nil; error = nil; save()
        let accepted = await session.send(envelope, editor: true)
        observeOutcome()
        if receipt == nil { error = session.editorError ?? "Отправка недоступна. Ввод сохранён." }
        return accepted
    }
    public func observeOutcome() {
        guard let receipt, handledID != receipt.envelope.commandId else { return }
        switch receipt.phase {
        case .applied:
            guard let settings else { return }
            handledID = receipt.envelope.commandId
            switch receipt.envelope.command {
            case .setMaxConcurrentRuns:
                draft?.baseline.maxConcurrentRuns = settings.maxConcurrentRuns
                draft?.ceiling = String(settings.maxConcurrentRuns)
            case .setQuotaOptions:
                draft?.baseline.quotaOptions = settings.quotaOptions
                draft?.options = settings.quotaOptions
                draft?.interval = String(settings.quotaOptions.pollInterval)
            default: break
            }
            draft?.handledID = handledID; error = nil; save()
        case .rejected(let failure):
            handledID = receipt.envelope.commandId; error = CommandErrorText.render(failure)
            draft?.handledID = handledID; save()
        default: break
        }
    }
    private func save() { storage.set(draft.flatMap { try? KabanCoding.makeEncoder().encode($0) }, forKey: key) }
}

public struct QuotaPresentation: Equatable, Sendable {
    public let percent: Double?
    public let message: String
    public let cycleFraction: Double?
    public let thresholdUsed: Double?
    public let resetAt: Date?
    public let resetCountdown: String?
    public let fetchedAt: Date?
    public init(pool: ModelPool, quota: QuotaState?, options: QuotaOptions?, flags: [SchedulerFlag], now: Date) {
        let enabled = options?.enabled == true && options?.consent == true
        let exhausted = flags.contains { if case .poolUsageExhausted(let p, _) = $0 { return p == pool }; return false }
        let reset = flags.compactMap { flag -> Date? in
            if case .poolUsageExhausted(let p, let date) = flag, p == pool { return date }; return nil
        }.first
        let raw = quota?.percentUsed(pool)
        let valid = raw.map { $0.isFinite && (0...100).contains($0) } == true
        let fresh = quota.map { !$0.isStale(now: now) && $0.fetchedAt <= now } == true
        percent = enabled ? (exhausted ? 100 : fresh && valid ? raw : nil) : nil
        message = !enabled ? "Выключено" : exhausted ? "Исчерпан" : !fresh && quota != nil
            ? "Нет свежих данных — работает реактивная схема" : percent == nil ? "Нет данных" : "Израсходовано"
        fetchedAt = enabled ? quota?.fetchedAt : nil
        resetAt = !enabled ? nil : exhausted ? reset : percent == nil ? nil : quota?.billingCycleEnd
        if let resetAt {
            let remaining = resetAt.timeIntervalSince(now)
            if remaining <= 0 { resetCountdown = "Ожидаем обновления источника после сброса" }
            else if remaining >= 86_400 { resetCountdown = "Сброс через \(Int(remaining / 86_400)) д" }
            else if remaining >= 3_600 { resetCountdown = "Сброс через \(Int(remaining / 3_600)) ч" }
            else { resetCountdown = "Сброс через \(max(1, Int(ceil(remaining / 60)))) мин" }
        } else { resetCountdown = nil }
        if enabled, !exhausted, percent != nil, let quota, let start = quota.effectiveCycleStart(),
           let end = quota.billingCycleEnd, end > start {
            cycleFraction = min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
        } else { cycleFraction = nil }
        let threshold = pool == .cm ? options?.thresholdCm : options?.thresholdOm
        thresholdUsed = percent != nil && threshold.map { $0.isFinite && (0...100).contains($0) } == true
            ? threshold.map { 100 - $0 } : nil
    }
}

public struct SchedulerFlagPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let command: Command?
    public let action: String?
    public let project: ProjectID?
    public init(_ flag: SchedulerFlag) {
        var project: ProjectID?
        switch flag {
        case .macPaused:
            title = "Новые запуски Мака на паузе"; detail = "Текущие запуски продолжаются."
            command = .resumeAll; action = "Продолжить"
        case .rateLimited(let date, _):
            title = "Лимит Cursor"; detail = "Возобновление: " + Self.date(date)
            command = .resumeAfterRateLimit; action = "Снять сейчас"
        case .usageExhaustedUnknown(let date):
            title = "Квота Cursor исчерпана · пул неизвестен"
            detail = date.map { "Сброс: " + Self.date($0) } ?? "Сброс неизвестен; проверка источника раз в 6 часов."
            command = nil; action = nil
        case .runnerUnavailable(let reason):
            title = "Cursor недоступен"
            switch reason {
            case .agentMissing: detail = "Cursor CLI не найден."
            case .agentNotRunnable: detail = "Cursor CLI не запускается."
            case .agentNotLoggedIn: detail = "Выполните cursor-agent login в Терминале."
            case .runnerAuth: detail = "Ошибка авторизации Cursor CLI."
            }
            command = .recheck(scope: .runner); action = "Проверить снова"
        case .poolUsageExhausted(let pool, let date):
            title = pool.rawValue.capitalized + " исчерпан"
            detail = (date.map { "Сброс: " + Self.date($0) } ?? "Дата сброса неизвестна.") + " Другой пул и текущие запуски продолжают работу."
            command = nil; action = nil
        case .projectPaused(let id):
            project = id; title = "Проект на паузе"; detail = "Текущие запуски продолжаются."
            command = .resumeProject(projectId: id); action = "Продолжить"
        case .intakePaused(let id):
            project = id; title = "Достигнут лимит ожидания человека"; detail = "Новые задачи из Backlog не берутся."
            command = nil; action = nil
        case .projectUnavailable(let id, let reason, let reported):
            project = id
            switch reason {
            case .projectMissing: title = "Папка проекта не найдена"
            case .noPipeline: title = "Нет пайплайна"
            case .pipelineInvalid: title = "Пайплайн невалиден"
            case .mcpUnexpected: title = "CLI видит лишний MCP-сервер"
            }
            detail = reported ?? "Откройте настройки проекта для исправления."
            command = .recheck(scope: .project(projectId: id)); action = "Проверить снова"
        case .mergeBlocked(let id):
            project = id; title = "Слияние ждёт правок main"; detail = "Проверьте пересекающиеся локальные правки."
            command = .recheck(scope: .project(projectId: id)); action = "Проверить снова"
        }
        self.project = project
    }
    public static func priority(_ flag: SchedulerFlag) -> Int {
        switch flag {
        case .runnerUnavailable: 0
        case .usageExhaustedUnknown: 1
        case .rateLimited: 2
        case .macPaused: 3
        case .poolUsageExhausted: 4
        default: 5
        }
    }
    private static func date(_ date: Date) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "ru_RU")
        format.dateStyle = .medium; format.timeStyle = .short
        return format.string(from: date)
    }
}
