// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CockpitKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CockpitTypes", targets: ["CockpitTypes"]),
        .library(name: "CockpitProtocol", targets: ["CockpitProtocol"]),
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
    ],
    swiftLanguageModes: [.v6]
)
