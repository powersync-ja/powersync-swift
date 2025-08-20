<p align="center">
  <a href="https://www.powersync.com" target="_blank"><img src="https://github.com/powersync-ja/.github/assets/7372448/d2538c43-c1a0-4c47-9a76-41462dba484f"/></a>
</p>

_[PowerSync](https://www.powersync.com) is a sync engine for building local-first apps with instantly-responsive UI/UX and simplified state transfer. Syncs between SQLite on the client-side and Postgres, MongoDB or MySQL on the server-side._

# PowerSync Swift

This is the PowerSync SDK for Swift clients. The SDK reference is available [here](https://docs.powersync.com/client-sdk-references/swift), API references are [documented here](https://powersync-ja.github.io/powersync-swift/documentation/powersync/).

## Structure: Packages

- [Sources](./Sources/PowerSync)

  - This is the Swift SDK implementation.

- [Sources](./Sources/StructuredQueries)

  - A typed query builder using [structured-queries](https://github.com/pointfreeco/swift-structured-queries).

## Demo Apps / Example Projects

The easiest way to test the PowerSync Swift SDK is to run our demo application.

- [Demo/PowerSyncExample](./Demo/README.md): A simple to-do list application demonstrating the use of the PowerSync Swift SDK using a Supabase connector.

- [Demo/StructuredQueriesExample](./Demo/StructuredQueriesExample/README.md): A simple Swift executable which uses the `PowerSyncStructuredQueries` library.

## Installation

Add

```swift
    dependencies: [
        ...
        .package(url: "https://github.com/powersync-ja/powersync-swift", from: "1.0.0")
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

to your `Package.swift` file.

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

The PowerSync Swift SDK makes use of the [PowerSync Kotlin Multiplatform SDK](https://github.com/powersync-ja/powersync-kotlin) and the API tool [SKIE](https://skie.touchlab.co/) under the hood to implement the Swift package.
However, this dependency is resolved internally and all public APIs are written entirely in Swift.

For more details, see the [Swift SDK reference](https://docs.powersync.com/client-sdk-references/swift) and generated [API references](https://powersync-ja.github.io/powersync-swift/documentation/powersync/).

## Attachments

See the attachments [README](./Sources/PowerSync/attachments/README.md) for more information.
