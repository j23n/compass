// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompassData",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CompassData", targets: ["CompassData"]),
    ],
    targets: [
        .target(name: "CompassData"),
        .testTarget(name: "CompassDataTests", dependencies: ["CompassData"]),
    ]
)
