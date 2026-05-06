import CSQLite
import Foundation

/// A lease representing a temporarily borrowed SQLite connection from the pool.
/// 
/// This is an internal protocol and should not be implemented outside of the PowerSync SDK.
public protocol SQLiteConnectionLease {
    /// Pointer to the underlying SQLite connection.
    /// This pointer should not be used outside of the closure which provided the lease.
    var pointer: OpaquePointer { borrowing get }

    /// Executes a SQL statement, returning the amount of affected rows.
    func execute(sql: String, parameters: [PowerSyncDataType?]) throws -> Int64

    /// Prepares a statement from the SQL text and parameters, then invokes callback with a cursor.
    func withIterator<T>(sql: String, parameters: [PowerSyncDataType?], callback: (SQLiteStatementIteratorProtocol) throws -> T) throws -> T
}

extension SQLiteConnectionLease {
    /// Default implementation of ``execute(sql:parameters:)`` based on raw sqlite3 APIs.
    public func execute(sql: String, parameters: [PowerSyncDataType?]) throws -> Int64 {
        do {
            var stmt = try NativeSqliteStatement(db: pointer, sql: sql)
            try stmt.bindValues(parameters)
            while try stmt.step() {
                // Iterate through the statement.
            }
        }

        return sqlite3_changes64(pointer)
    }

    /// Default implementation of ``withIterator(sql:parameters:callback:)`` based on raw sqlite3 APIs.
    public func withIterator<T>(sql: String, parameters: [PowerSyncDataType?], callback: (SQLiteStatementIteratorProtocol) throws -> T) throws -> T {
        var stmt = try NativeSqliteStatement(db: pointer, sql: sql)
        try stmt.bindValues(parameters)
        return try withUnsafeMutablePointer(to: &stmt) { ptr in
            let iterator = NativeStatementIterator(stmt: ptr)
            return try callback(iterator)
        }
    }
}

private struct NativeStatementIterator: SQLiteStatementIteratorProtocol {
    var stmt: UnsafeMutablePointer<NativeSqliteStatement>
    
    func next<T>(callback: (any SqlCursor) throws -> T) throws -> T? {
        return try stmt.pointee.stepWithCursor(callback: callback)
    }
}

public protocol SQLiteStatementIteratorProtocol {
    func next<T>(callback: (_ cursor: SqlCursor) throws -> T) throws -> T?
}

/// An implementation of a connection pool providing asynchronous access to a single writer and multiple readers.
/// This is the underlying pool implementation on which the higher-level PowerSync Swift SDK is built on.
/// 
/// This is an internal protocol and should not be implemented outside of the PowerSync SDK.
public protocol SQLiteConnectionPoolProtocol: Sendable {
    var tableUpdates: AsyncStream<Set<String>> { get }

    /// Calls the callback with a read-only connection temporarily leased from the pool.
    func read<T: Sendable>(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> T,
    ) async throws -> T

    /// Calls the callback with a read-write connection temporarily leased from the pool.
    func write<T: Sendable>(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> T,
    ) async throws -> T

    /// Invokes the callback with all connections leased from the pool.
    func withAllConnections<T: Sendable>(
        onConnection: @Sendable @escaping (
            _ writer: SQLiteConnectionLease,
            _ readers: [SQLiteConnectionLease]
        ) throws -> T,
    ) async throws -> T

    /// Closes the connection pool and associated resources.
    func close() async throws
}
