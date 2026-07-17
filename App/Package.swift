// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vedetta",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Core models and logic, UI-independent where possible.
        .target(name: "VedettaKit"),
        // The menu bar app.
        .executableTarget(
            name: "Vedetta",
            dependencies: ["VedettaKit"]
        ),
        // The hook bridge: tiny, dependency-free, fast to spawn. Invoked by
        // Claude Code hooks, forwards the payload to the app's socket.
        .executableTarget(name: "VedettaBridge"),
        .testTarget(
            name: "VedettaKitTests",
            dependencies: ["VedettaKit"]
        ),
    ]
)
