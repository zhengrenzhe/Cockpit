// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CockpitKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CockpitTypes", targets: ["CockpitTypes"]),
        .library(name: "CockpitProtocol", targets: ["CockpitProtocol"]),
        .library(name: "CockpitClientCore", targets: ["CockpitClientCore"]),
        .library(name: "CockpitHostCore", targets: ["CockpitHostCore"]),
        .library(name: "CockpitTerminalCore", targets: ["CockpitTerminalCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .target(name: "CockpitTypes"),
        .testTarget(name: "CockpitTypesTests", dependencies: ["CockpitTypes"]),
        .target(
            name: "CockpitProtocol",
            dependencies: [
                "CockpitTypes",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            resources: [
                .copy("Proto/swift-protobuf-config.json"),
            ],
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "CockpitProtocolTests",
            dependencies: ["CockpitProtocol"]
        ),
        .target(name: "CockpitClientCore", dependencies: ["CockpitTypes", "CockpitProtocol"]),
        .target(name: "CockpitHostCore", dependencies: ["CockpitTypes", "CockpitProtocol"]),
        .target(name: "CockpitTerminalCore", dependencies: ["CockpitTypes", "CockpitProtocol"]),
        .testTarget(
            name: "CockpitClientCoreTests",
            dependencies: ["CockpitClientCore", "CockpitTypes", "CockpitProtocol"]
        ),
        .testTarget(
            name: "CockpitHostCoreTests",
            dependencies: ["CockpitHostCore", "CockpitTypes", "CockpitProtocol"]
        ),
        .testTarget(
            name: "CockpitTerminalCoreTests",
            dependencies: ["CockpitTerminalCore", "CockpitTypes", "CockpitProtocol"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
