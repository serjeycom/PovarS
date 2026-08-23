// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Povar",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Povar",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ]
        ),
        .testTarget(
            name: "PovarTests",
            dependencies: [
                "Povar",
                .product(name: "XCTVapor", package: "vapor")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
