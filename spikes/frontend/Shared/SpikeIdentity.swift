import Foundation

/// Одноразовые имена спайка. Это не контракт `KabanProtocol`.
enum SpikeIdentity {
    static let subsystem = "app.kaban.spikes"
    static let appBundleID = "app.kaban.spikes"
    static let agentLabel = "app.kaban.spikes.agent"
    static let machService = "app.kaban.spikes.agent"
    static let plistName = "app.kaban.spikes.agent.plist"

    /// Кандидат bundle id Cursor. НЕ ПРОВЕРЕНО на машине владельца:
    /// `osascript -e 'id of app "Cursor"'`.
    static let cursorBundleIDCandidate = "com.todesktop.230313mzl4w4u92"
}
