// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchUsage", targets: ["NotchUsage"])
    ],
    targets: [
        .executableTarget(
            name: "NotchUsage",
            path: "Sources/NotchUsage"
        )
    ]
)
