// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cooldown",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Cooldown", targets: ["Cooldown"])],
    targets: [
        .executableTarget(name: "Cooldown", path: "Sources/Cooldown")
    ]
)
