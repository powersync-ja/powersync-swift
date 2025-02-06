# Changelog

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
