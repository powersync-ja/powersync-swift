# Changelog

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
