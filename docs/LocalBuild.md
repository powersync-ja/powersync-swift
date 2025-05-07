# PowerSync Swift SDK

## Run against a local Kotlin build

Especially when working on the Kotlin SDK, it may be helpful to test your local changes
with the Swift SDK too.
To do this, first create an XCFramework from your Kotlin checkout:

```bash
./gradlew PowerSyncKotlin:assemblePowerSyncKotlinDebugXCFramework
```

Then, point the `binaryTarget` dependency in `Package.swift` towards the path of your generated
XCFramework:

```Swift
.binaryTarget(
    name: "PowerSyncKotlin",
    path: "/path/to/powersync-kotlin/PowerSyncKotlin/build/XCFrameworks/debug/PowerSyncKotlin.xcframework"
)
```

Subsequent Kotlin changes should get picked up after re-assembling the Kotlin XCFramework.
