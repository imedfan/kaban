import os

/// Точки для Instruments → Points of Interest. Имена литералы: OSSignposter требует StaticString.
enum SpikeSignpost {
    private static let signposter = OSSignposter(
        subsystem: SpikeIdentity.subsystem,
        category: "PointsOfInterest"
    )

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}
