// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WorktreeManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WorktreeManager")
    ]
)
