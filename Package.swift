// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RenommageAudio",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "RenommageAudio", targets: ["RenommageAudio"]),
    ],
    targets: [
        // Moteur pur : analyse des noms, tags ID3, plan, application. Sans interface.
        .target(name: "AudioRenamerCore", path: "Sources/AudioRenamerCore"),
        // Interface macOS (AppKit).
        .executableTarget(
            name: "RenommageAudio",
            dependencies: ["AudioRenamerCore"],
            path: "Sources/RenommageAudio"
        ),
        .testTarget(
            name: "AudioRenamerCoreTests",
            dependencies: ["AudioRenamerCore"],
            path: "Tests/AudioRenamerCoreTests"
        ),
    ]
)
