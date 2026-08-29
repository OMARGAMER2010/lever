// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lever",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lever", targets: ["Lever"])
    ],
    targets: [
        .target(name: "LeverCore"),
        .executableTarget(name: "Lever", dependencies: ["LeverCore"]),
        .executableTarget(
            name: "LeverTests",
            dependencies: ["LeverCore"],
            path: "Tests/LeverTests"
        )
    ]
)
