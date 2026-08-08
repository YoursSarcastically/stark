// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Stark",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Stark",
            path: "Sources/Stark",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
