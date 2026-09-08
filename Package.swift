// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "longbrew",
    platforms: [.macOS(.v13)],   // SMAppService.daemon + XPC code-signing pinning
    targets: [
        // XPC contract shared by the app and the root helper.
        .target(name: "LongbrewShared"),
        .executableTarget(
            name: "longbrew",
            dependencies: ["LongbrewShared"],
            path: "Sources/longbrew",
            resources: [.process("Resources")]
        ),
        // Runs as root via SMAppService; embedded in the app bundle.
        .executableTarget(
            name: "LongbrewHelper",
            dependencies: ["LongbrewShared"]
        ),
    ]
)
