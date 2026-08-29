// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExeRar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ExeRar", targets: ["ExeRar"])
    ],
    targets: [
        .target(name: "ExeRarCore"),
        .executableTarget(name: "ExeRar", dependencies: ["ExeRarCore"]),
        .executableTarget(
            name: "ExeRarTests",
            dependencies: ["ExeRarCore"],
            path: "Tests/ExeRarTests"
        )
    ]
)
