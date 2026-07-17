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
        .testTarget(
            name: "VedettaKitTests",
            dependencies: ["VedettaKit"]
        ),
    ]
)
