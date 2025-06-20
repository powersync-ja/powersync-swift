// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
let packageName = "PowerSync"

// Set this to the absolute path of your Kotlin SDK checkout if you want to use a local Kotlin
// build. Also see docs/LocalBuild.md for details
let localKotlinSdkOverride: String? = nil

// Our target and dependency setup is different when a local Kotlin SDK is used. Without the local
// SDK, we have no package dependency on Kotlin and download the XCFramework from Kotlin releases as
// a binary target.
// With a local SDK, we point to a `Package.swift` within the Kotlin SDK containing a target pointing
// towards a local framework build
var conditionalDependencies: [Package.Dependency] = []
var conditionalTargets: [Target] = []
var kotlinTargetDependency = Target.Dependency.target(name: "PowerSyncKotlin")

if let kotlinSdkPath = localKotlinSdkOverride {
    // We can't depend on local XCFrameworks outside of this project's root, so there's a Package.swift
    // in the PowerSyncKotlin project pointing towards a local build.
    conditionalDependencies.append(.package(path: "\(kotlinSdkPath)/PowerSyncKotlin"))

    kotlinTargetDependency = .product(name: "PowerSyncKotlin", package: "PowerSyncKotlin")
} else {
    // Not using a local build, so download from releases
    conditionalTargets.append(.binaryTarget(
        name: "PowerSyncKotlin",
        url: "https://github.com/powersync-ja/powersync-kotlin/releases/download/v1.2.0/PowersyncKotlinRelease.zip",
        checksum: "7454481a245b46b1b63a42419ec27f88f2fcb7fba9b763e3085cb49db59dfd58"
    ))
}

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
        .package(url: "https://github.com/powersync-ja/powersync-sqlite-core-swift.git", exact: "0.4.0")
    ] + conditionalDependencies,
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: packageName,
            dependencies: [
                kotlinTargetDependency,
                .product(name: "PowerSyncSQLiteCore", package: "powersync-sqlite-core-swift")
            ]),
        .testTarget(
            name: "PowerSyncTests",
            dependencies: ["PowerSync"]
        ),
    ] + conditionalTargets
)
