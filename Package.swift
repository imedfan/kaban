// swift-tools-version: 6.0

import PackageDescription

// Headless core and its transactional SQLite store build on macOS and Linux.
// PackageDescription 6.0 не содержит MacOSVersion.v15 (последний кейс — v14).
// Строка "15.0" — тот же минимум macOS 15, что и .v15 на более новом tools-version.
let package = Package(
    name: "Kaban",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "KabanProtocol", targets: ["KabanProtocol"]),
        .library(name: "KabanKit", targets: ["KabanKit"]),
        .library(name: "KabanBoardCore", targets: ["KabanBoardCore"]),
        .library(name: "KabanDaemonCore", targets: ["KabanDaemonCore"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.4.0")],
    targets: [
        .target(name: "KabanDaemonCore", dependencies: ["KabanKit", "KabanProtocol", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "KabanDaemonCoreTests", dependencies: ["KabanDaemonCore"]),
        .target(name: "KabanProtocol"),
        .target(
            name: "KabanKit",
            dependencies: ["KabanProtocol"]
        ),
        .target(
            name: "KabanBoardCore",
            dependencies: ["KabanProtocol"],
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "KabanProtocolTests",
            dependencies: ["KabanProtocol"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "KabanKitTests",
            dependencies: ["KabanKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "KabanBoardCoreTests",
            dependencies: ["KabanBoardCore"],
            resources: [.copy("Resources/test-vectors.json")]
        ),
    ]
)
