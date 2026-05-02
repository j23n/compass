// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompassFIT",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CompassFIT", targets: ["CompassFIT"]),
    ],
    dependencies: [
        .package(name: "FitFileParser", path: "../FitFileParser"),
        .package(name: "CompassData", path: "../CompassData"),
    ],
    targets: [
        .target(
            name: "CompassFIT",
            dependencies: [
                .product(name: "FitFileParser", package: "FitFileParser"),
                "CompassData",
            ]
        ),
        .testTarget(
            name: "CompassFITTests",
            dependencies: ["CompassFIT"]
        ),
    ]
)
