// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lever",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lever", targets: ["Lever"]),
        .library(name: "LeverInputBridge", type: .dynamic, targets: ["LeverInputBridge"])
    ],
    targets: [
        .target(name: "LeverCore"),
        .target(name: "LeverInputState"),
        .target(name: "LeverInputBridge", dependencies: ["LeverInputState"],
                cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("QuartzCore")]),
        .executableTarget(name: "Lever", dependencies: ["LeverCore"]),
        .executableTarget(
            name: "LeverTests",
            dependencies: ["LeverCore"],
            path: "Tests/LeverTests"
        )
    ]
)
