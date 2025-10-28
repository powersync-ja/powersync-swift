// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let packageName = "PowerSync"

// Set this to the absolute path of your Kotlin SDK checkout if you want to use a local Kotlin
// build. Also see docs/LocalBuild.md for details
let localKotlinSdkOverride: String? = nil
// Set this to the absolute path of your powersync-sqlite-core checkout if you want to use a
// local build of the core extension.
let localCoreExtension: String? = nil

// Our target and dependency setup is different when a local Kotlin SDK is used. Without the local
// SDK, we have no package dependency on Kotlin and download the XCFramework from Kotlin releases as
// a binary target.
// With a local SDK, we point to a `Package.swift` within the Kotlin SDK containing a target pointing
// towards a local framework build
var conditionalDependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/sbooth/CSQLite.git",
        from: "3.50.4",
        traits: [
            .defaults,
            // CSQLite uses THREADSAFE=0 by default, which breaks PowerSync because we're using SQLite on
            // multiple threads (it can lead to race conditions when closing connections sharing resources
            // like shared memory, causing crashes).
            // THREADSAFE=2 overrides the default, and is safe to use as long as a single SQLite connection
            // is not shared between threads.
            // TODO: Technically, we should not use .defaults because there's a logical conflict between
            // the threadsafe options. Instead, we should spell out all defaults again and remove that
            // thread-safety option.
            // However, despite the docs explicitly saying something else, it looks like there's no way to
            // disable default traits anyway (XCode compiles sqlite3.c with the default option even without
            // .defaults being included here).
            "THREADSAFE_2",
            "ENABLE_SESSION"
        ]
    )
]
var conditionalTargets: [Target] = []
var kotlinTargetDependency = Target.Dependency.target(name: "PowerSyncKotlin")

if let kotlinSdkPath = localKotlinSdkOverride {
    // We can't depend on local XCFrameworks outside of this project's root, so there's a Package.swift
    // in the PowerSyncKotlin project pointing towards a local build.
    conditionalDependencies.append(.package(path: "\(kotlinSdkPath)/internal/PowerSyncKotlin"))

    kotlinTargetDependency = .product(name: "PowerSyncKotlin", package: "PowerSyncKotlin")
} else {
    // Not using a local build, so download from releases
    conditionalTargets.append(.binaryTarget(
        name: "PowerSyncKotlin",
        url: "https://github.com/powersync-ja/powersync-kotlin/releases/download/v1.8.0/PowersyncKotlinRelease.zip",
        checksum: "31ac7c5e11d747e11bceb0b34f30438d37033e700c621b0a468aa308d887587f"
    ))
}

var corePackageName = "powersync-sqlite-core-swift"
if let corePath = localCoreExtension {
    conditionalDependencies.append(.package(path: corePath))
    corePackageName = "powersync-sqlite-core"
} else {
    // Not using a local build, so download from releases
    conditionalDependencies.append(.package(
        url: "https://github.com/powersync-ja/powersync-sqlite-core-swift.git",
        exact: "0.4.8"
    ))
}

let package = Package(
    name: packageName,
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v9)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: packageName,
            targets: ["PowerSync"]
        ),
        .library(
            name: "\(packageName)Dynamic",
            // The default value normally specifies that the library is compatible with both static and dynamic linking,
            // where the value used is typically specified by the consumer - which is usually defaulted to static linking.
            // It's not straight forward to configure the linking option used by XCode consumers - specifying
            // this additional product allows consumers to add it to their project, forcing dynamic linking.
            // Dynamic linking is particularly important for XCode previews.
            type: .dynamic,
            targets: ["PowerSync"]
        ),
        .library(
            name: "PowerSyncGRDB",
            targets: ["PowerSyncGRDB"]
        )
    ],
    dependencies: conditionalDependencies + [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.7.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: packageName,
            dependencies: [
                kotlinTargetDependency,
                .product(name: "PowerSyncSQLiteCore", package: corePackageName),
                .product(name: "CSQLite", package: "CSQLite")
            ]
        ),
        .target(
            name: "PowerSyncGRDB",
            dependencies: [
                .target(name: "PowerSync"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "PowerSyncTests",
            dependencies: ["PowerSync"]
        ),
        .testTarget(
            name: "PowerSyncGRDBTests",
            dependencies: ["PowerSync", "PowerSyncGRDB"]
        )
    ] + conditionalTargets
)
