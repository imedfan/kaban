import Foundation

/// Единые настройки JSON для всего протокола: даты ISO 8601 с миллисекундами, ключи как в Swift (camelCase).
public enum KabanCoding {
    public static let protocolVersion = 1

    public static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.format(date))
        }
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISO8601.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Не ISO 8601: \(s)")
            }
            return date
        }
        return d
    }

    enum ISO8601 {
        static func format(_ date: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: date)
        }
        static func parse(_ s: String) -> Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
    }
}

/// Помощник для перечислений вида `{"type": "...", "data": {...}}`.
enum TaggedKeys: String, CodingKey { case type, data }

/// Неизвестный тег не роняет клиента: старый клиент получает `.unknown(type)` и может запросить снимок.
public struct UnknownTag: Error, Equatable, Sendable { public let type: String }
