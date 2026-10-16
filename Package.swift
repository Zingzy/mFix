// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mFix",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "mFixCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(name: "mFix", dependencies: ["mFixCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "mFixTests", dependencies: ["mFixCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
