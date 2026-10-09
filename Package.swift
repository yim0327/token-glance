// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "token-glance",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenGlanceApp", targets: ["TokenGlanceApp"]),
        .executable(name: "token-glance-hook", targets: ["token-glance-hook"]),
        .library(name: "TokenGlanceCore", targets: ["TokenGlanceCore"]),
    ],
    targets: [
        .target(name: "TokenGlanceCore"),
        // User-facing text (English/Korean) built from Core values. Resources are .strings files:
        // String Catalogs are not compiled by SwiftPM with the Command Line Tools (see docs/adr/0002).
        .target(
            name: "TokenGlanceText",
            dependencies: ["TokenGlanceCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "TokenGlanceApp",
            dependencies: ["TokenGlanceCore", "TokenGlanceText"]
        ),
        .executableTarget(
            name: "token-glance-hook",
            dependencies: ["TokenGlanceCore"]
        ),
        .testTarget(
            name: "TokenGlanceCoreTests",
            dependencies: ["TokenGlanceCore"]
        ),
        .testTarget(
            name: "TokenGlanceTextTests",
            dependencies: ["TokenGlanceText", "TokenGlanceCore"]
        ),
    ]
)
