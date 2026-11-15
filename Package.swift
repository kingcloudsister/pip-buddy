// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pip",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Pip", path: "Sources/Pip")
    ]
)
