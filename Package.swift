// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cooldown",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .executable(name: "Cooldown", targets: ["Cooldown"]),
        .library(name: "CooldownLink", targets: ["CooldownLink"]),
    ],
    targets: [
        .target(name: "CooldownLink", path: "Sources/CooldownLink"),
        .executableTarget(name: "Cooldown", dependencies: ["CooldownLink"], path: "Sources/Cooldown"),
        .testTarget(name: "CooldownLinkTests", dependencies: ["CooldownLink"], path: "Tests/CooldownLinkTests"),
        .testTarget(name: "CooldownTests", dependencies: ["Cooldown", "CooldownLink"], path: "Tests/CooldownTests"),
    ]
)
