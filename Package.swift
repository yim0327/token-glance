// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "token-glance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenGlanceApp", targets: ["TokenGlanceApp"]),
        .executable(name: "token-glance-hook", targets: ["token-glance-hook"]),
        .library(name: "TokenGlanceCore", targets: ["TokenGlanceCore"]),
    ],
    targets: [
        .target(name: "TokenGlanceCore"),
        .executableTarget(
            name: "TokenGlanceApp",
            dependencies: ["TokenGlanceCore"]
        ),
        .executableTarget(
            name: "token-glance-hook",
            dependencies: ["TokenGlanceCore"]
        ),
        .testTarget(
            name: "TokenGlanceCoreTests",
            dependencies: ["TokenGlanceCore"]
        ),
    ]
)
