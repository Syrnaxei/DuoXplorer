// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuoXplore",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DuoXplore",
            path: "Sources/DuoXplore",
            resources: [
                .copy("../../AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "DuoXploreTests",
            dependencies: ["DuoXplore"]
        ),
    ]
)
