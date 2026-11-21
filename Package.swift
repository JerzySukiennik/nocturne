// swift-tools-version: 6.2
// Nocturne: personal AI photo editor for macOS. Kit (engine, library, AI), SwiftUI app, CLI test tool.
import PackageDescription

let package = Package(
    name: "Nocturne",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "NocturneKit", path: "Sources/NocturneKit"),
        .executableTarget(name: "Nocturne", dependencies: ["NocturneKit"], path: "Sources/Nocturne"),
        .executableTarget(name: "nocturnetool", dependencies: ["NocturneKit"], path: "Sources/nocturnetool")
    ],
    swiftLanguageModes: [.v5]
)
