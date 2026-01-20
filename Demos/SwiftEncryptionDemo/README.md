# PowerSync encryption demo

A tiny app opening an encrypted database with PowerSync.

This example only opens a local database and does not setup a sync client.
Since encryption happens at a low level using SQLite3 Multiple Ciphers, all regular PowerSync APIs are available
for encrypted databases too.

## Setup

PowerSync has no builtin encryption primitives, but can be made to work with [SQLite3 Multiple Ciphers](https://utelle.github.io/SQLite3MultipleCiphers/) (`sqlite3mc`).
By using the `initialStatements` parameter when opening databases, you can run `PRAGMA key` statements to configure
encryption.

To use `sqlite3mc` instead of regular `sqlite3`, note that PowerSync depends on [this project](github.com/powersync-ja/CSQLite) to compile and link SQLite into your app.
To support encryption, enable the `Encryption` trait for that package. Since XCode doesn't support package traits, the
workaround is to create a SwiftPM project in your XCode project (called `helper/` in this demo).
In `helper/Package.swift`, depend on CSQLite with the `Encryption` trait:

```Swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "helper",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "helper",
            targets: ["helper"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/powersync-ja/CSQLite.git", exact: "3.51.2", traits: ["Encryption"]),
    ],
    targets: [
        .target(
            name: "helper",
            dependencies: [.product(name: "CSQLite", package: "CSQLite")]
        ),
    ]
)
```

Note that `Sources/helper/helper.swift` can be an empty file, but it needs to exist for this to compile.

Next, add a dependency to this local project from XCode and resolve packages. This will enable your entire app, including
the PowerSync framework, to use `sqlite3mc`.

Finally, add `initialStatements` to encrypt databases:

```Swift
let ps = PowerSyncDatabase(
    schema: yourSchema,
    initialStatements: ["pragma key = 'TODO: your key'"]
)
```
