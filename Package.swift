// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EmbeddedMockEngine",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "EmbeddedMockEngine",
            type: .dynamic,
            targets: ["EmbeddedMockEngine"]
        )
    ],
    targets: [
        .target(
            name: "EmbeddedMockEngine",
            path: "Sources/EmbeddedMockEngine"
        ),
        .testTarget(
            name: "EmbeddedMockEngineTests",
            dependencies: ["EmbeddedMockEngine"],
            path: "Tests/EmbeddedMockEngineTests",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
