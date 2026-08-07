// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorktreeManager",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Swift Testing ships in the Swift 6 toolchain, but not usably here:
        // Command Line Tools include Testing.framework without the
        // `_TestingInternals` module it is built from, so `import Testing`
        // fails without Xcode. Hence the package — test target only, the app
        // links nothing extra.
        //
        // Pinned rather than tracked: 0.99.x is the stub that only warns
        // "remove this dependency", and the 6.x releases need a newer
        // swift-syntax than this toolchain's macro support can build. 0.12.0 is
        // the last release that compiles here. Drop the dependency entirely
        // once Xcode is installed — the sources need no other change.
        .package(url: "https://github.com/swiftlang/swift-testing", exact: "0.12.0"),
    ],
    targets: [
        .executableTarget(name: "WorktreeManager", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "WorktreeManagerTests",
            dependencies: [
                "WorktreeManager",
                .product(name: "Testing", package: "swift-testing"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
