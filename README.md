<p align="center">
  <a href="https://www.powersync.com" target="_blank"><img src="https://github.com/powersync-ja/.github/assets/7372448/d2538c43-c1a0-4c47-9a76-41462dba484f"/></a>
</p>

_[PowerSync](https://www.powersync.com) is a sync engine for building local-first apps with instantly-responsive UI/UX and simplified state transfer. Syncs between SQLite on the client-side and Postgres, MongoDB or MySQL on the server-side._

# PowerSync Swift

This is the PowerSync SDK for Swift clients. The SDK reference is available [here](https://docs.powersync.com/client-sdk-references/swift).

## Beta Release

This SDK is currently in a beta release it is suitable for production use, given you have tested your use case(s) extensively. If you find a bug or issue, please open a [GitHub issue](https://github.com/powersync-ja/powersync-swift/issues). Questions or feedback can be posted on our [community Discord](https://discord.gg/powersync) - we'd love to hear from you.

## Structure: Packages

- [Sources](./Sources/)

  - This is the Swift SDK implementation.

## Demo Apps / Example Projects

The easiest way to test the PowerSync Swift SDK is to run our demo application.

- [Demo/PowerSyncExample](./Demo/README.md): A simple to-do list application demonstrating the use of the PowerSync Swift SDK using a Supabase connector.

## Installation

Add

```swift
    dependencies: [
        ...
        .package(url: "https://github.com/powersync-ja/powersync-swift", exact: "<version>")
    ],
    targets: [
        .target(
            name: "YourTargetName",
            dependencies: [
                ...
                .product(
                    name: "PowerSync",
                    package: "powersync-swift"
                ),
            ]
        )
    ]
```

to your `Package.swift` file and pin the dependency to a specific version. The version is required because the package is in beta.

to your `Package.swift` file and pin the dependency to a specific version. This is required because the package is in beta.

## Usage

Create a PowerSync client

```swift
import PowerSync

let powersync = PowerSyncDatabase(
    schema: Schema(
        tables: [
            Table(
                name: "users",
                columns: [
                    .text("count"),
                    .integer("is_active"),
                    .real("weight"),
                    .text("description")
                ]
            )
        ]
    ),
    logger: DefaultLogger(minSeverity: .debug)
)
```

## Underlying Kotlin Dependency

The PowerSync Swift SDK currently makes use of the [PowerSync Kotlin Multiplatform SDK](https://github.com/powersync-ja/powersync-kotlin) with the API tool [SKIE](https://skie.touchlab.co/) and KMMBridge under the hood to help generate and publish a native Swift package. We will move to an entirely Swift native API in v1 and do not expect there to be any breaking changes. For more details, see the [Swift SDK reference](https://docs.powersync.com/client-sdk-references/swift).

## Migration from Alpha to Beta

See these [developer notes](https://docs.powersync.com/client-sdk-references/swift#migrating-from-the-alpha-to-the-beta-sdk) if you are migrating from the alpha to the beta version of the Swift SDK.

## Attachments

See the attachments [README](./Sources/PowerSync/attachments/README.md) for more information.
