// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Liftoff",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Liftoff",
            path: "Sources/Liftoff",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
