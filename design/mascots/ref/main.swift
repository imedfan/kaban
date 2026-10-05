// swiftc MascotKit.swift main.swift -o /tmp/mkcheck && /tmp/mkcheck  — prints the same vectors as test-vectors.json
let seeds = ["p-kaban", "p-site", "shop-api", "mobile-app", "docs-site", "infra", "",
             "8a60b3cc-6141-80fc-8008-bbcd3bd40972", "проект-кабан", "p-kaban#1"]
func hex(_ v: UInt64) -> String { let s = String(v, radix: 16); return "0x" + String(repeating: "0", count: 16 - s.count) + s }
for s in seeds { let p = MascotKit.pick(seed: s); print("\(s)\t\(hex(MascotKit.fnv1a64(s)))\t\(p.mascotIndex)\t\(p.texture.rawValue)\t\(p.emoji)\t\(p.texture.key)") }
let board = MascotKit.resolveBoard([("p-kaban", "p-kaban"), ("p-site", "p-site"), ("shop-api", "shop-api"), ("mobile-app", "mobile-app"), ("docs-site", "docs-site"), ("p-crm-4", "p-crm-4")])
print("bump p-crm-4 ->", board["p-crm-4"]!.mascotIndex, board["p-crm-4"]!.texture.key)
print("picker", MascotKit.seed(for: "p-kaban", mascotIndex: 1, texture: .stripes) ?? "nil")
