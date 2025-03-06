# Changelog

## 1.0.0-Beta.8

* Improved watch query internals. Added the ability to throttle watched queries.

## 1.0.0-Beta.7

* Fixed an issue where throwing exceptions in the query `mapper` could cause a runtime crash.
* Internally improved type casting.

## 1.0.0-Beta.6

* BREAKING CHANGE: `watch` queries are now throwable and therefore will need to be accompanied by a `try` e.g.

```swift
try database.watch()
```

* BREAKING CHANGE: `transaction` functions are now throwable and therefore will need to be accompanied by a `try` e.g.

```swift
try await database.writeTransaction { transaction in
  try transaction.execute(...)
}
```
* Allow `execute` errors to be handled
* `userId` is now set to `nil` by default and therefore it is no longer required to be set to `nil` when instantiating `PowerSyncCredentials` and can therefore be left out.

## 1.0.0-Beta.5

* Implement improvements to errors originating in Kotlin so that they can be handled in Swift
* Improve `__fetchCredentials`to log the error but not cause an app crash on error


## 1.0.0-Beta.4

* Allow cursor to use column name to get value by including the following functions that accept a column name parameter:
`getBoolean`,`getBooleanOptional`,`getString`,`getStringOptional`, `getLong`,`getLongOptional`, `getDouble`,`getDoubleOptional`
* BREAKING CHANGE: This should not affect anyone but made `KotlinPowerSyncCredentials`, `KotlinPowerSyncDatabase` and `KotlinPowerSyncBackendConnector` private as these should never have been public.


## 1.0.0-Beta.3

* BREAKING CHANGE: Update underlying powersync-kotlin package to BETA18.0 which requires transactions to become synchronous as opposed to asynchronous.
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

* Upgrade PowerSyncSqliteCore to 0.3.8

## 1.0.0-Beta.1

* Initial Beta release
