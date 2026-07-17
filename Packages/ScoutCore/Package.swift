// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScoutCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ScoutCore", targets: ["ScoutCore"]),
    ],
    targets: [
        .target(name: "ScoutCore"),
        .testTarget(name: "ScoutCoreTests", dependencies: ["ScoutCore"]),
    ],
    swiftLanguageModes: [.v6]
)
