# Changelog

## 1.1.1 (unreleased)

* Improved `CrudBatch` and `CrudTransaction` `complete` function extensions. Developers no longer need to specify `nil` as an argument for `writeCheckpoint` when calling `CrudBatch.complete`. The base `complete` functions still accept an optional `writeCheckpoint` argument if developers use custom write checkpoints. 
``` diff
guard let finalBatch = try await powersync.getCrudBatch(limit: 100) else {
  return nil
}
- try await batch.complete(writeCheckpoint: nil)
+ try await batch.complete()
```
* Fix reported progress around compactions / defrags on the sync service.
* Support version `0.4.0` of the core extension, which improves sync performance.

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
