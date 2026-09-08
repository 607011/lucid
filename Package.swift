// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Lucid",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Lucid",
            path: "Sources/Lucid"
        )
    ]
)
