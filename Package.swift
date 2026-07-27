// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexPotion",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexPotion", targets: ["CodexPotion"])
    ],
    targets: [
        .executableTarget(
            name: "CodexPotion",
            path: "Sources/CodexPotion"
        )
    ]
)
