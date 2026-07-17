// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScoutPersistence",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ScoutPersistence", targets: ["ScoutPersistence"]),
    ],
    dependencies: [
        .package(path: "../ScoutCore"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"]),
            ]
        ),
        .target(
            name: "ScoutPersistence",
            dependencies: [
                "CSQLite",
                .product(name: "ScoutCore", package: "ScoutCore"),
            ]
        ),
        .testTarget(
            name: "ScoutPersistenceTests",
            dependencies: [
                "CSQLite",
                "ScoutPersistence",
                .product(name: "ScoutCore", package: "ScoutCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
