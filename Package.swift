// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Helipad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Helipad", path: "Sources/Helipad")
    ]
)
