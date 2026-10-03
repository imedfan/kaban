import Foundation

/// Хранилище настроек приложения (не демон). На macOS это обёртка над `UserDefaults`.
public protocol KeyValueStoring: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// Память для тестов и превью. Потокобезопасна.
public final class MemoryKeyValueStore: KeyValueStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let data {
            values[key] = data
        } else {
            values.removeValue(forKey: key)
        }
    }
}
