// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "courier-bridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CourierCore", targets: ["CourierCore"]),
        .executable(name: "courier-bridge", targets: ["CourierBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.0"),
        .package(url: "https://github.com/vapor/jwt.git", exact: "5.0.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", exact: "5.2.0"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "CourierCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "CourierBridge",
            dependencies: [
                "CourierCore",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "JWT", package: "jwt"),
            ],
            resources: [
                .copy("Public"),
            ]
        ),
        .testTarget(
            name: "CourierCoreTests",
            dependencies: [
                "CourierCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
