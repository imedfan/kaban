import Foundation

/// Типизированные идентификаторы. На проводе это обычная строка.
public protocol KabanID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral where RawValue == String {
    init(rawValue: String)
}

public extension KabanID {
    init(stringLiteral value: String) { self.init(rawValue: value) }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    var description: String { rawValue }
}

public struct ProjectID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct TaskID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct RunID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct StageID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct ModelID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct IncidentID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct DenialID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct GrantID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct ArtifactID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct HumanRequestID: KabanID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }

/// UUID команды от клиента (§5): ответ и журнальное событие несут тот же `commandId`.
public typealias CommandID = UUID

/// Номер события в журнале `event`.
public typealias Seq = Int64
