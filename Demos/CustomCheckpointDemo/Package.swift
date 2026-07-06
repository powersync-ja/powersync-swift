// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CustomCheckpointDemo",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "CustomCheckpointDemo",
            dependencies: [
                .product(name: "PowerSync", package: "powersync-swift"),
            ]
        ),
    ]
)
