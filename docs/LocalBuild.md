# PowerSync Swift SDK

## Run against a local Kotlin build

Especially when working on the Kotlin SDK, it may be helpful to test your local changes
with the Swift SDK too.
To do this, first create an XCFramework from your Kotlin checkout:

```bash
./gradlew PowerSyncKotlin:assemblePowerSyncKotlinDebugXCFramework
```

Next, you need to update the `Package.swift` to, instead of downloading a
prebuilt XCFramework archive from a Kotlin release, use your local build.
For this, set the `localKotlinSdkOverride` variable to your path:

```Swift
let localKotlinSdkOverride: String? = "/path/to/powersync-kotlin/"
```

Subsequent Kotlin changes should get picked up after re-assembling the Kotlin XCFramework.
