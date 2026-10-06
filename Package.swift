// swift-tools-version: 6.1

import PackageDescription

// Headless core and its transactional SQLite store build on macOS and Linux.
// macOS 15 remains the deployment minimum; GRDB requires Swift tools 6.1.
let package = Package(
    name: "Kaban",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "KabanProtocol", targets: ["KabanProtocol"]),
        .library(name: "KabanKit", targets: ["KabanKit"]),
        .library(name: "KabanBoardCore", targets: ["KabanBoardCore"]),
        .library(name: "KabanDaemonCore", targets: ["KabanDaemonCore"]),
        .library(name: "KabanTransport", targets: ["KabanTransport"]),
        .executable(name: "KabanDaemon", targets: ["KabanDaemon"]),
        .executable(name: "kabanctl", targets: ["kabanctl"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "KabanDaemonCore", dependencies: ["KabanKit", "KabanProtocol", "KabanTransport", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "KabanDaemonCoreTests", dependencies: ["KabanDaemonCore", "KabanBoardCore"]),
        .target(name: "KabanTransport", dependencies: ["KabanProtocol"]),
        .executableTarget(name: "KabanDaemon", dependencies: ["KabanDaemonCore", "KabanTransport"]),
        .executableTarget(name: "kabanctl", dependencies: ["KabanTransport"]),
        .testTarget(name: "KabanTransportTests", dependencies: ["KabanTransport", "KabanDaemonCore", "KabanBoardCore"]),
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
