import Foundation

/// Одноразовые сообщения спайка. Не импортировать в `KabanProtocol`.
enum SpikeRequest: Codable, Sendable {
    case ping
    case subscribe(fromSeq: UInt64)
    case append(note: String)
    /// Удалить события с `seq` строго меньше порога. Дырка в журнале → `resyncRequired`.
    case trimBelow(seq: UInt64)
    case postNotification(kind: SpikeNotificationKind)
}

enum SpikeNotificationKind: String, Codable, Sendable {
    case question
    case incident
}

struct SpikeEvent: Codable, Sendable, Identifiable, Equatable {
    var seq: UInt64
    var kind: String
    var note: String
    var id: UInt64 { seq }
}

struct SpikePong: Codable, Sendable, Equatable {
    var pid: Int32
    var bootID: String
    var seq: UInt64
    var teamID: String?
    var bundleID: String?
}

struct SpikeSubscription: Codable, Sendable, Equatable {
    var bootID: String
    var events: [SpikeEvent]
    var nextSeq: UInt64
    var resyncRequired: Bool
    var reason: String
}

struct SpikeNotificationAttempt: Codable, Sendable, Equatable {
    var ok: Bool
    var message: String
}

enum SpikeReply: Codable, Sendable {
    case pong(SpikePong)
    case subscription(SpikeSubscription)
    case appended(seq: UInt64)
    case trimmed(remaining: Int, minSeq: UInt64)
    case notificationAttempt(SpikeNotificationAttempt)
    case failed(String)
}
