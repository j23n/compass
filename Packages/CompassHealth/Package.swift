// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompassHealth",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CompassHealth", targets: ["CompassHealth"]),
    ],
    dependencies: [
        .package(name: "CompassData", path: "../CompassData"),
    ],
    targets: [
        .target(
            name: "CompassHealth",
            dependencies: ["CompassData"]
        ),
        .testTarget(
            name: "CompassHealthTests",
            dependencies: ["CompassHealth"]
        ),
    ]
)
