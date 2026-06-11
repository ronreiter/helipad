// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudePRHover",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ClaudePRHover", path: "Sources/ClaudePRHover")
    ]
)
