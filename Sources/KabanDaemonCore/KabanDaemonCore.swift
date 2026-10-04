import Foundation
import KabanKit
import KabanProtocol

/// Portable headless coordinator. External effect workers are intentionally not connected yet.
public struct KabanDaemonCore: Sendable {
    public let store: KabanStore
    public init(store: KabanStore) { self.store = store }

    /// Recovery is repeatable: only running/gating tasks receive the reducer restart event.
    /// The recovery pass token allows replay after a crash without duplicate journal entries.
    public func recover(passId: UUID, at: Date) throws -> [DurableReceipt] {
        try store.recover(passId: passId, at: at)
    }
}
