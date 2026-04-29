// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompassBLE",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CompassBLE", targets: ["CompassBLE"]),
    ],
    targets: [
        .target(name: "CompassBLE"),
        .testTarget(name: "CompassBLETests", dependencies: ["CompassBLE"]),
        .testTarget(name: "CompassBLEIntegrationTests", dependencies: ["CompassBLE"]),
    ]
)
