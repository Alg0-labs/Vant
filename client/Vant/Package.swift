// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Vant",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Vant",
            path: "Vant",
            exclude: [
                "Info.plist",
                "Vant.entitlements",
            ]
        )
    ]
)
