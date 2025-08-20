import Foundation
import PowerSync
import StructuredQueriesCore

public extension StructuredQueriesCore.Statement {
    /// Executes a structured query on the given database connection.
    ///
    /// For example:
    ///
    /// ```swift
    /// let db = PowerSyncDatabase(...)
    /// try await Player.insert { $0.name } values: { "Arthur" }
    ///     .execute(db)
    /// // INSERT INTO "players" ("name")
    /// // VALUES ('Arthur');
    /// ```
    ///
    /// - Parameter powerSync: A PowerSync database connection.
    @inlinable
    @MainActor
    func execute(_ powerSync: PowerSyncDatabaseProtocol) async throws where QueryValue == () {
        let preparedQuery = query.prepareSqlite()
        try await powerSync.execute(
            sql: preparedQuery.sql,
            parameters: preparedQuery.bindings.map { try $0.powerSyncValue }
        )
    }

    /// Returns an array of all values fetched from the database.
    ///
    /// For example:
    ///
    /// ```swift
    /// let db = PowerSyncDatabase(...)
    /// let lastName = "O'Reilly"
    /// let players = try await Player
    ///     .where { $0.lastName == lastName }
    ///     .fetchAll(db)
    /// // SELECT … FROM "players"
    /// // WHERE "players"."lastName" = 'O''Reilly'
    /// ```
    ///
    /// - Parameter powerSync: A PowerSync database connection.
    /// - Returns: An array of all values decoded from the database.
    @inlinable
    func fetchAll(_ powerSync: PowerSyncDatabaseProtocol) async throws -> [QueryValue.QueryOutput]
        where QueryValue: QueryRepresentable
    {
        let cursor: QueryValueCursor<Self.QueryValue> = try QueryValueCursor<QueryValue>(
            powerSync: powerSync,
            query: query
        )
        return try await cursor.elements()
    }

    /// Returns a single value fetched from the database.
    ///
    /// For example:
    ///
    /// ```swift
    /// let db = PowerSyncDatabase(...)
    /// let lastName = "O'Reilly"
    /// let player = try await Player
    ///     .where { $0.lastName == lastName }
    ///     .limit(1)
    ///     .fetchOne(db)
    /// // SELECT … FROM "players"
    /// // WHERE "players"."lastName" = 'O''Reilly'
    /// // LIMIT 1
    /// ```
    ///
    /// - Parameter powerSync: A PowerSync database connection.
    /// - Returns: A single value decoded from the database.
    @inlinable
    func fetchOne(_ powerSync: PowerSyncDatabaseProtocol) async throws -> QueryValue.QueryOutput?
        where QueryValue: QueryRepresentable
    {
        let all = try await fetchAll(powerSync)
        return all.first
    }
}

public extension SelectStatement where QueryValue == (), Joins == () {
    /// Returns the number of rows fetched by the query.
    ///
    /// For example:
    ///
    /// ```swift
    /// let db = PowerSyncDatabase(...)
    /// let count = try await Player.all.fetchCount(db)
    /// ```
    ///
    /// - Parameter powerSync: A PowerSync database connection.
    /// - Returns: The number of rows fetched by the query.
    @inlinable
    func fetchCount(_ powerSync: PowerSyncDatabaseProtocol) async throws -> Int {
        let query = asSelect().count()
        return try await query.fetchOne(powerSync) ?? 0
    }
}

extension SelectStatement where QueryValue == (), Joins == () {
    /// Returns an array of all values fetched from the database.
    ///
    /// For example:
    ///
    /// ```swift
    /// let db = PowerSyncDatabase(...)
    /// let users = try await User.all.fetchAll(db)
    /// ```
    ///
    /// - Parameter powerSync: A PowerSync database connection.
    /// - Returns: An array of all values decoded from the database.
    @_documentation(visibility: private)
    @inlinable
    public func fetchAll(_ powerSync: PowerSyncDatabaseProtocol) async throws -> [From.QueryOutput] {
        let cursor = try QueryValueCursor<From>(
            powerSync: powerSync,
            query: query
        )
        return try await cursor.elements()
    }

    /// Returns a single value fetched from the database.
    ///
    /// For example:
    ///
    /// ```swift
    /// let db = PowerSyncDatabase(...)
    /// let user = try await User.all.fetchOne(db)
    /// ```
    ///
    /// - Parameter powerSync: A PowerSync database connection.
    /// - Returns: A single value decoded from the database.
    @_documentation(visibility: private)
    @inlinable
    public func fetchOne(_ powerSync: PowerSyncDatabaseProtocol) async throws -> From.QueryOutput? {
        let all = try await fetchAll(powerSync)
        return all.first
    }
}
