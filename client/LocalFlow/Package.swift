// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LocalFlow",
            path: "LocalFlow",
            exclude: [
                "Info.plist",
                "LocalFlow.entitlements",
            ]
        )
    ]
)
