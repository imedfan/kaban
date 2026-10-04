// swift-tools-version: 6.0

import PackageDescription

// Каркас пакета. KabanProtocol и KabanBoardCore наполнены; KabanKit пока заглушка.
// KabanDaemonCore и GRDB не подключать — их добавит бэкенд отдельным PR.
// PackageDescription 6.0 не содержит MacOSVersion.v15 (последний кейс — v14).
// Строка "15.0" — тот же минимум macOS 15, что и .v15 на более новом tools-version.
let package = Package(
    name: "Kaban",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "KabanProtocol", targets: ["KabanProtocol"]),
        .library(name: "KabanKit", targets: ["KabanKit"]),
        .library(name: "KabanBoardCore", targets: ["KabanBoardCore"]),
    ],
    targets: [
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
            dependencies: ["KabanKit"]
        ),
        .testTarget(
            name: "KabanBoardCoreTests",
            dependencies: ["KabanBoardCore"],
            resources: [.copy("Resources/test-vectors.json")]
        ),
    ]
)
