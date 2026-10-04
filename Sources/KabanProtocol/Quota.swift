import Foundation

/// Состояние проактивной квоты (§7). `nil` у процента — «нет данных», а не 0%.
public struct QuotaState: Codable, Hashable, Sendable {
    public var cm: Double?
    public var om: Double?
    public var billingCycleStart: Date?
    public var billingCycleEnd: Date?
    public var fetchedAt: Date

    public init(cm: Double?, om: Double?, billingCycleStart: Date? = nil, billingCycleEnd: Date?, fetchedAt: Date) {
        self.cm = cm; self.om = om; self.billingCycleStart = billingCycleStart; self.billingCycleEnd = billingCycleEnd; self.fetchedAt = fetchedAt
    }

    public func percentUsed(_ pool: ModelPool) -> Double? { pool == .cm ? cm : om }

    /// Начало цикла: из ответа, иначе календарно тот же день месяцем раньше (не «минус 30 дней»).
    public func effectiveCycleStart(calendar: Calendar = .utc) -> Date? {
        if let billingCycleStart { return billingCycleStart }
        guard let end = billingCycleEnd else { return nil }
        return BillingCycle.startFallback(end: end, calendar: calendar)
    }

    /// Данные старше `staleAfter` (по умолчанию 30 мин) считаются неизвестными.
    public func isStale(now: Date, staleAfter: TimeInterval = 30 * 60) -> Bool { now.timeIntervalSince(fetchedAt) > staleAfter }
}

public enum BillingCycle {
    /// Тот же день прошлого месяца; если такого дня нет (31 марта → 28/29 февраля), Calendar берёт последний день месяца.
    public static func startFallback(end: Date, calendar: Calendar = .utc) -> Date? {
        calendar.date(byAdding: .month, value: -1, to: end)
    }

    /// `billingCycleEnd` в ответе `GetCurrentPeriodUsage` — строка с миллисекундами эпохи.
    public static func parseEpochMillis(_ raw: String?) -> Date? {
        guard let raw, let ms = Double(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

public extension Calendar {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}
