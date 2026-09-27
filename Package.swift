// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "DeepSeek",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "DeepSeek",
            path: "Sources/DeepSeek",
            swiftSettings: [
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
