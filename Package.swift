// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Palanca",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Palanca", targets: ["Palanca"])
    ],
    targets: [
        .target(name: "PalancaCore"),
        .executableTarget(name: "Palanca", dependencies: ["PalancaCore"]),
        .executableTarget(
            name: "PalancaTests",
            dependencies: ["PalancaCore"],
            path: "Tests/PalancaTests"
        )
    ]
)
