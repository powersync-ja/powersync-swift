// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
let packageName = "PowerSync"

let package = Package(
    name: packageName,
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: packageName,
            targets: ["PowerSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/powersync-ja/powersync-kotlin.git", "1.0.1+SWIFT.0"..<"1.1.0+SWIFT.0"),
        .package(url: "https://github.com/powersync-ja/powersync-sqlite-core-swift.git", "0.3.14"..<"0.4.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: packageName,
            dependencies: [
                .product(name: "PowerSyncKotlin", package: "powersync-kotlin"),
                .product(name: "PowerSyncSQLiteCore", package: "powersync-sqlite-core-swift")
            ]),
        .testTarget(
            name: "PowerSyncTests",
            dependencies: ["PowerSync"]
        ),
    ]
)
