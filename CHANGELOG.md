# Changelog

## 1.8.0 (unreleased)

* Enable the `newClientImplementation` by default. This should improve performance and memory usage.
* **Potential Breaking Change** The `newClientImplementation` now uses WebSockets to connect to the PowerSync service. These WebSockets connections do not log events to `SyncClientConfiguration->requestLogger`.
* Add the `soft` flag to `disconnectAndClear()` which keeps an internal copy of synced data in the database, allowing faster re-sync if a compatible token is used in the next connect() call
* Added Alpha `PowerSyncGRDB` product which supports sharing GRDB `DatabasePool`s with PowerSync and application logic.
* Update PowerSync SQLite core to 0.4.10
* Update Kotlin SDK to 1.7.0.


## 1.7.0

* Update Kotlin SDK to 1.7.0.
* Add `close(deleteDatabase:)` method to `PowerSyncDatabaseProtocol` for deleting SQLite database files when closing the database. This includes the main database file and all WAL mode files (.wal, .shm, .journal). Files that don't exist are ignored, but an error is thrown if a file exists but cannot be deleted.

```swift
// Close the database and delete all SQLite files
try await database.close(deleteDatabase: true)

// Close the database without deleting files (default behavior)
try await database.close(deleteDatabase: false)
// or simply
try await database.close()
```
* Add `PowerSyncDataTypeConvertible` protocol for casting query parameters to SQLite supported types.
* [Internal] Removed unnecessary `Task` creation in Attachment helper `FileManagerStorageAdapter`.

## 1.6.0

* Update core extension to 0.4.6 ([changelog](https://github.com/powersync-ja/powersync-sqlite-core/releases/tag/v0.4.6))
* Add `getCrudTransactions()`, returning an async sequence of transactions.
* Compatibility with Swift 6.2 and XCode 26.
* Update minimum MacOS target to v12
* Update minimum iOS target to v15
* [Attachment Helpers] Added automatic verification or records' `local_uri` values on `AttachmentQueue` initialization. 
initialization can be awaited with `AttachmentQueue.waitForInit()`. `AttachmentQueue.startSync()` also performs this verification.
`waitForInit()` is only recommended if `startSync` is not called directly after creating the queue.

## 1.5.1

* Update core extension to 0.4.5 ([changelog](https://github.com/powersync-ja/powersync-sqlite-core/releases/tag/v0.4.5))
* Additional Swift 6 Strict Concurrency Checking declarations added for remaining protocols.
* Fix issue in legacy sync client where local writes made offline could have their upload delayed until a keepalive event was received. This could also cause downloaded updates to be delayed even further until all uploads were completed.

## 1.5.0

* Fix null values in CRUD entries being reported as strings.
* Added support for Swift 6 strict concurrency checking.
  - Accepted query parameter types have been updated from `[Any]` to `[Sendable]`. This should cover all supported query parameter types.
  - Query and lock methods' return `Result` generic types now should extend `Sendable`.
  - Deprecated default `open class PowerSyncBackendConnector`. Devs should preferably implement the `PowerSyncBackendConnectorProtocol`

* *Potential Breaking Change*: Attachment helpers have been updated to better support Swift 6 strict concurrency checking. `Actor` isolation is improved, but developers who customize or extend `AttachmentQueue` will need to update their implementations. The default instantiation of `AttachmentQueue` remains unchanged.
`AttachmentQueueProtocol` now defines the basic requirements for an attachment queue, with most base functionality provided via an extension. Custom implementations should extend `AttachmentQueueProtocol`.
* Added `PowerSyncDynamic` product to package. Importing this product should restore XCode preview functionality.
* [Internal] Instantiate Kotlin Kermit logger directly.
* [Internal] Improved connection context error handling.

## 1.4.0

* Added the ability to log PowerSync sync network requests.

```swift
try await database.connect(
    connector: Connector(),
    options: ConnectOptions(
        clientConfiguration: SyncClientConfiguration(
            requestLogger: SyncRequestLoggerConfiguration(
                requestLevel: .headers
            ) { message in
                // Handle Network request logs here
                print(message)
            }
        )
    )
)
```

* Update core extension to 0.4.4, fixing a bug where `hasSynced` would turn `false` when losing connectivity.

## 1.3.1

* Update SQLite to 3.50.3.
* Support receiving binary sync lines over HTTP when the Rust client is enabled.
* Remove the experimental websocket transport mode.

## 1.3.0

* Use version `0.4.2` of the PowerSync core extension, which improves the reliability
  of the new Rust client implementation.
* Add support for [raw tables](https://docs.powersync.com/usage/use-case-examples/raw-tables), which
  are custom tables managed by the user instead of JSON-based views managed by the SDK.
* Fix attachments never downloading again when the sandbox path of the app (e.g. on the simulator)
  changes.

## 1.2.1

* Use version `0.4.1` of the PowerSync core extension, which fixes an issue with the
  new Rust client implementation.
* Fix crud uploads when web sockets are used as a connection method.

## 1.2.0

* Improved `CrudBatch` and `CrudTransaction` `complete` function extensions. Developers no longer need to specify `nil` as an argument for `writeCheckpoint` when calling `CrudBatch.complete`. The base `complete` functions still accept an optional `writeCheckpoint` argument if developers use custom write checkpoints. 
``` diff
guard let finalBatch = try await powersync.getCrudBatch(limit: 100) else {
  return nil
}
- try await batch.complete(writeCheckpoint: nil)
+ try await batch.complete()
```
* Fix reported progress around compactions / defrags on the sync service.
* Use version `0.4.0` of the PowerSync core extension, which improves sync performance.
* Add a new sync client implementation written in Rust instead of Kotlin. While this client is still
  experimental, we intend to make it the default in the future. The main benefit of this client is
  faster sync performance, but upcoming features will also require this client. We encourage 
  interested users to try it out by opting in to experimental APIs and passing options when
  connecting:
  ```Swift
  @_spi(PowerSyncExperimental) import PowerSync

  try await db.connect(connector: connector, options: ConnectOptions(
      newClientImplementation: true,
  ))
  ```
  Switching between the clients can be done at any time without compatibility issues. If you run
  into issues with the new client, please reach out to us!
* In addition to HTTP streams, the Swift SDK also supports fetching sync instructions from the
  PowerSync service in a binary format. This requires the new sync client, and can then be enabled
  on the sync options:
  ```Swift
  @_spi(PowerSyncExperimental) import PowerSync

  try await db.connect(connector: connector, options: ConnectOptions(
      newClientImplementation: true,
      connectionMethod: .webSocket,
  ))
  ```

## 1.1.0

* Add sync progress information through `SyncStatusData.downloadProgress`.
* Add `trackPreviousValues` option on `Table` which sets `CrudEntry.previousValues` to previous values on updates.
* Add `trackMetadata` option on `Table` which adds a `_metadata` column that can be used for updates.
  The configured metadata is available through `CrudEntry.metadata`.
* Add `ignoreEmptyUpdates` option which skips creating CRUD entries for updates that don't change any values.

# 1.0.0

- Improved the stability of watched queries. Watched queries were previously susceptible to runtime crashes if an exception was thrown in the update stream. Errors are now gracefully handled.

- Deprecated `PowerSyncCredentials` `userId` field. This value is not used by the PowerSync service.

- Added `readLock` and `writeLock` APIs. These methods allow obtaining a SQLite connection context without starting a transaction.

- Removed references to the PowerSync Kotlin SDK from all public API protocols. Dedicated Swift protocols are now defined. These protocols align better with Swift primitives. See the `BRAKING CHANGES` section for more details. Updated protocols include:

  - `ConnectionContext` - The context provided by `readLock` and `writeLock`
  - `Transaction` - The context provided by `readTransaction` and `writeTransaction`
  - `CrudBatch` - Response from `getCrudBatch`
  - `CrudTransaction` Response from `getNextCrudTransaction`
  - `CrudEntry` - Crud entries for `CrudBatch` and `CrudTransaction`
  - `UpdateType` - Operation type for `CrudEntry`s
  - `SqlCursor` - Cursor used to map SQLite results to typed result sets
  - `JsonParam` - JSON parameters used to declare client parameters in the `connect` method
  - `JsonValue` - Individual JSON field types for `JsonParam`

- Database and transaction/lock level query `execute` methods now have `@discardableResult` annotation.

- Query methods' `parameters` typing has been updated to `[Any?]` from `[Any]`. This makes passing `nil` or optional values to queries easier.

- `AttachmentContext`, `AttachmentQueue`, `AttachmentService` and `SyncingService` are are now explicitly declared as `open` classes, allowing them to be subclassed outside the defining module.

**BREAKING CHANGES**:

- Completing CRUD transactions or CRUD batches, in the `PowerSyncBackendConnector` `uploadData` handler, now has a simpler invocation.

```diff
- _ = try await transaction.complete.invoke(p1: nil)
+ try await transaction.complete()
```

- `index` based `SqlCursor` getters now throw if the query result column value is `nil`. This is now consistent with the behaviour of named column getter operations. New `getXxxxxOptional(index: index)` methods are available if the query result value could be `nil`.

```diff
let results = try transaction.getAll(
                sql: "SELECT * FROM my_table",
                parameters: [id]
            ) { cursor in
-                 cursor.getString(index: 0)!
+                 cursor.getStringOptional(index: 0)
+                 // OR
+                 // try cursor.getString(index: 0) // if the value should be required
            }
```

- `SqlCursor` getters now directly return Swift types. `getLong` has been replaced with `getInt64`.

```diff
let results = try transaction.getAll(
                sql: "SELECT * FROM my_table",
                parameters: [id]
            ) { cursor in
-                 cursor.getBoolean(index: 0)?.boolValue,
+                 cursor.getBooleanOptional(index: 0),
-                 cursor.getLong(index: 0)?.int64Value,
+                 cursor.getInt64Optional(index: 0)
+                 // OR
+                 // try cursor.getInt64(index: 0) // if the value should be required
            }
```

- Client parameters now need to be specified with strictly typed `JsonValue` enums.

```diff
try await database.connect(
    connector: PowerSyncBackendConnector(),
    params: [
-        "foo": "bar"
+        "foo": .string("bar")
    ]
)
```

- `SyncStatus` values now use Swift primitives for status attributes. `lastSyncedAt` now is of `Date` type.

```diff
- let lastTime: Date? = db.currentStatus.lastSyncedAt.map {
-     Date(timeIntervalSince1970: TimeInterval($0.epochSeconds))
- }
+ let time: Date? = db.currentStatus.lastSyncedAt
```

- `crudThrottleMs` and `retryDelayMs` in the `connect` method have been updated to `crudThrottle` and `retryDelay` which are now of type `TimeInterval`. Previously the parameters were specified in milliseconds, the `TimeInterval` typing now requires values to be specified in seconds.

```diff
try await database.connect(
            connector: PowerSyncBackendConnector(),
-           crudThrottleMs: 1000,
-           retryDelayMs: 5000,
+           crudThrottle: 1,
+           retryDelay: 5,
            params: [
                "foo": .string("bar"),
            ]
        )
```

- `throttleMs` in the watched query `WatchOptions` has been updated to `throttle` which is now of type `TimeInterval`. Previously the parameters were specified in milliseconds, the `TimeInterval` typing now requires values to be specified in seconds.

```diff
let stream = try database.watch(
            options: WatchOptions(
                sql: "SELECT name FROM users ORDER BY id",
-               throttleMs: 1000,
+               throttle: 1,
                mapper: { cursor in
                    try cursor.getString(index: 0)
                }
            ))
```

# 1.0.0-Beta.13

- Update `powersync-kotlin` dependency to version `1.0.0-BETA32`, which includes:
  - Removed unnecessary `User-Id` header from internal PowerSync service requests.
  - Fix `getNextCrudTransaction()` only returning a single item.

# 1.0.0-Beta.12

- Added attachment sync helpers
- Added support for cancellations in watched queries

# 1.0.0-beta.11

- Fix deadlock when `connect()` is called immediately after opening a database.

# 1.0.0-Beta.10

- Added the ability to specify a custom logging implementation

```swift
  let db = PowerSyncDatabase(
    schema: Schema(
        tables: [
            Table(
                name: "users",
                columns: [
                    .text("name"),
                    .text("email")
                ]
            )
        ]
    ),
    logger: DefaultLogger(minSeverity: .debug)
)
```

- added `.close()` method on `PowerSyncDatabaseProtocol`
- Update `powersync-kotlin` dependency to version `1.0.0-BETA29`, which fixes these issues:
  - Fix potential race condition between jobs in `connect()` and `disconnect()`.
  - Fix race condition causing data received during uploads not to be applied.
  - Fixed issue where automatic driver migrations would fail with the error:

```
Sqlite operation failure database is locked attempted to run migration and failed. closing connection
```

## 1.0.0-Beta.9

- Update PowerSync SQLite core extension to 0.3.12.
- Added queuing protection and warnings when connecting multiple PowerSync clients to the same database file.
- Improved concurrent SQLite connection support. A single write connection and multiple read connections are used for concurrent read queries.
- Internally improved the linking of SQLite.
- Enabled Full Text Search support.
- Added the ability to update the schema for existing PowerSync clients.
- Fixed bug where local only, insert only and view name overrides were not applied for schema tables.

## 1.0.0-Beta.8

- Improved watch query internals. Added the ability to throttle watched queries.
- Added support for sync bucket priorities.

## 1.0.0-Beta.7

- Fixed an issue where throwing exceptions in the query `mapper` could cause a runtime crash.
- Internally improved type casting.

## 1.0.0-Beta.6

- BREAKING CHANGE: `watch` queries are now throwable and therefore will need to be accompanied by a `try` e.g.

```swift
try database.watch()
```

- BREAKING CHANGE: `transaction` functions are now throwable and therefore will need to be accompanied by a `try` e.g.

```swift
try await database.writeTransaction { transaction in
  try transaction.execute(...)
}
```

- Allow `execute` errors to be handled
- `userId` is now set to `nil` by default and therefore it is no longer required to be set to `nil` when instantiating `PowerSyncCredentials` and can therefore be left out.

## 1.0.0-Beta.5

- Implement improvements to errors originating in Kotlin so that they can be handled in Swift
- Improve `__fetchCredentials`to log the error but not cause an app crash on error

## 1.0.0-Beta.4

- Allow cursor to use column name to get value by including the following functions that accept a column name parameter:
  `getBoolean`,`getBooleanOptional`,`getString`,`getStringOptional`, `getLong`,`getLongOptional`, `getDouble`,`getDoubleOptional`
- BREAKING CHANGE: This should not affect anyone but made `KotlinPowerSyncCredentials`, `KotlinPowerSyncDatabase` and `KotlinPowerSyncBackendConnector` private as these should never have been public.

## 1.0.0-Beta.3

- BREAKING CHANGE: Update underlying powersync-kotlin package to BETA18.0 which requires transactions to become synchronous as opposed to asynchronous.
  ```swift
  try await database.writeTransaction { transaction in
    try await transaction.execute(
      sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
      parameters: ["1", "Test User", "test@example.com"]
    )
  }
  ```
  to
  ```swift
  try await database.writeTransaction { transaction in
    transaction.execute( // <- This has become synchronous
      sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
      parameters: ["1", "Test User", "test@example.com"]
    )
  }
  ```

## 1.0.0-Beta.2

- Upgrade PowerSyncSqliteCore to 0.3.8

## 1.0.0-Beta.1

- Initial Beta release
