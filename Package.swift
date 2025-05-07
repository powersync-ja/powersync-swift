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
        .package(url: "https://github.com/powersync-ja/powersync-sqlite-core-swift.git", "0.3.14"..<"0.4.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: packageName,
            dependencies: [
                .target(name: "PowerSyncKotlin"),
                .product(name: "PowerSyncSQLiteCore", package: "powersync-sqlite-core-swift")
            ]),
        .testTarget(
            name: "PowerSyncTests",
            dependencies: ["PowerSync"]
        ),
        // If you want to use a local build, comment out this reference and update the other.
        // See docs/LocalBuild.md
        .binaryTarget(
            name: "PowerSyncKotlin",
            // TODO: Use GitHub release once https://github.com/powersync-ja/powersync-kotlin/releases/tag/untagged-fde4386dec502ec27067 is published
            url: "https://fsn1.your-objectstorage.com/simon-public/powersync.zip",
            checksum: "b6770dc22ae31315adc599e653fea99614226312fe861dbd8764e922a5a83b09"
        ),
        // .binaryTarget(
        //     name: "PowerSyncKotlin",
        //     path: "/path/to/powersync-kotlin/PowerSyncKotlin/build/XCFrameworks/debug/PowerSyncKotlin.xcframework"
        // )
    ]
)
