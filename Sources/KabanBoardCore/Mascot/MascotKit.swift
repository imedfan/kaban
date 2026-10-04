// Kaban mascot kit v1 — reference for KabanBoardCore. Pure Swift, no imports, macOS + Linux.
// ORDER of `mascots` and `EdgeTexture` cases is part of the spec: never reorder, insert or remove.

public enum EdgeTexture: Int, CaseIterable, Sendable {
    case dots = 0, stripes, crosshatch, waves, zigzag, grid, chevrons, solidThin
    public var key: String {
        switch self {
        case .dots: "dots"; case .stripes: "stripes"; case .crosshatch: "crosshatch"; case .waves: "waves"
        case .zigzag: "zigzag"; case .grid: "grid"; case .chevrons: "chevrons"; case .solidThin: "solid-thin"
        }
    }
}

public struct MascotPick: Equatable, Sendable {
    public let mascotIndex: Int
    public let texture: EdgeTexture
    public var emoji: String { MascotKit.mascots[mascotIndex] }
}

public enum MascotKit {
    public static let version = 1
    public static let mascots: [String] = [
        "🦊", "🐗", "🦉", "🦔", "🐺", "🦌", "🦝", "🐰",   // лес
        "🐱", "🐶", "🦙",                                   // домашние
        "🐧", "🐼", "🐨", "🦭",                             // север
        "🦁", "🦒", "🦓", "🦛",                             // саванна
        "🐳", "🐬", "🦈", "🐙", "🐠", "🦦",                 // вода
        "🐢", "🦖",                                         // рептилии
        "🦋", "🦚", "🦄",                                   // крылья и сказка
    ]

    /// FNV-1a 64 over the UTF-8 bytes of the seed (no normalisation, no trimming).
    public static func fnv1a64(_ seed: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// N = 30 (not a power of two, so `% N` uses all 64 bits). mascot = h % N, texture = (h / N) % 8.
    public static func pick(seed: String) -> MascotPick {
        let h = fnv1a64(seed), n = UInt64(mascots.count), t = UInt64(EdgeTexture.allCases.count)
        return MascotPick(mascotIndex: Int(h % n), texture: EdgeTexture(rawValue: Int((h / n) % t))!)
    }

    /// Display-only collision avoidance. `projects` in the order they were ADDED to the board
    /// (BoardSetStore append order, not current lane order). A later project with the same
    /// (mascot, texture) bumps its texture +1, +2 … (mod 8). The mascot never changes. Never persisted.
    public static func resolveBoard(_ projects: [(id: String, seed: String)]) -> [String: MascotPick] {
        var taken = Set<Int>(), out: [String: MascotPick] = [:]
        let tc = EdgeTexture.allCases.count
        for p in projects {
            let base = pick(seed: p.seed)
            var tex = base.texture.rawValue
            for k in 0..<tc {
                let t = (base.texture.rawValue + k) % tc
                if !taken.contains(base.mascotIndex * tc + t) { tex = t; break }
            }
            taken.insert(base.mascotIndex * tc + tex)
            out[p.id] = MascotPick(mascotIndex: base.mascotIndex, texture: EdgeTexture(rawValue: tex)!)
        }
        return out
    }

    /// MascotPicker: seed for `setMascot(projectId, seed)` that yields the chosen pair.
    /// Smallest k ≥ 1 with pick("\(projectId)#\(k)") == target.
    public static func seed(for projectId: String, mascotIndex: Int, texture: EdgeTexture, maxTries: Int = 100_000) -> String? {
        for k in 1...maxTries {
            let s = "\(projectId)#\(k)", p = pick(seed: s)
            if p.mascotIndex == mascotIndex && p.texture == texture { return s }
        }
        return nil
    }
}
