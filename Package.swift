// swift-tools-version: 6.0

import PackageDescription

// Каркас пакета. Модули пустые: типы и логику добавляют отдельные PR.
// GRDB сюда не подключать — зависимость добавит бэкенд вместе с KabanStore.
let package = Package(
    name: "Kaban",
    products: [
        .library(name: "KabanProtocol", targets: ["KabanProtocol"]),
        .library(name: "KabanKit", targets: ["KabanKit"]),
        .library(name: "KabanBoardCore", targets: ["KabanBoardCore"]),
    ],
    targets: [
        .target(name: "KabanProtocol"),
        .target(name: "KabanKit"),
        .target(
            name: "KabanBoardCore",
            dependencies: [
                "KabanProtocol",
                "KabanKit",
            ]
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
            dependencies: ["KabanBoardCore"]
        ),
    ]
)
