// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExeRar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ExeRar", targets: ["ExeRar"])
    ],
    targets: [
        .executableTarget(name: "ExeRar"),
        .testTarget(name: "ExeRarTests", dependencies: ["ExeRar"])
    ]
)
