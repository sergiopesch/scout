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
        .library(name: "ScoutLocalReviewAuthority", targets: ["ScoutLocalReviewAuthority"]),
    ],
    targets: [
        .target(name: "ScoutCore"),
        .target(
            name: "ScoutLocalReviewAuthority",
            dependencies: ["ScoutCore"],
            linkerSettings: [.linkedFramework("LocalAuthentication")]
        ),
        .testTarget(name: "ScoutCoreTests", dependencies: ["ScoutCore"]),
        .testTarget(
            name: "ScoutLocalReviewAuthorityTests",
            dependencies: ["ScoutCore", "ScoutLocalReviewAuthority"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
