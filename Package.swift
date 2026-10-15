// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Snap11",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "Snap11Core",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(name: "Snap11", dependencies: ["Snap11Core"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "Snap11Tests", dependencies: ["Snap11Core"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
