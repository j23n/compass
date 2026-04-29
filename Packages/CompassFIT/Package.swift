// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompassFIT",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CompassFIT", targets: ["CompassFIT"]),
    ],
    dependencies: [
        .package(name: "CompassData", path: "../CompassData"),
    ],
    targets: [
        .target(
            name: "CompassFIT",
            dependencies: ["CompassData"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CompassFITTests",
            dependencies: ["CompassFIT"]
        ),
    ]
)
