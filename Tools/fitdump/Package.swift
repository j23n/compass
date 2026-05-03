// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fitdump",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/CompassFIT"),
        .package(path: "../../Packages/CompassData"),
        .package(path: "../../Packages/FitFileParser"),
    ],
    targets: [
        .executableTarget(
            name: "fitdump",
            dependencies: [
                .product(name: "CompassFIT", package: "CompassFIT"),
                .product(name: "CompassData", package: "CompassData"),
                .product(name: "FitFileParser", package: "FitFileParser"),
            ],
            path: "Sources"
        ),
    ]
)
