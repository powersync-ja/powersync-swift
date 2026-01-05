import Foundation

/// A lease representing a temporarily borrowed SQLite connection from the pool.
public protocol SQLiteConnectionLease {
    /// Pointer to the underlying SQLite connection.
    /// This pointer should not be used outside of the closure which provided the lease.
    var pointer: OpaquePointer { get }
}

/// An implementation of a connection pool providing asynchronous access to a single writer and multiple readers.
/// This is the underlying pool implementation on which the higher-level PowerSync Swift SDK is built on.
public protocol SQLiteConnectionPoolProtocol: Sendable {
    var tableUpdates: AsyncStream<Set<String>> { get }

    /// Calls the callback with a read-only connection temporarily leased from the pool.
    func read(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> Void,
    ) async throws

    /// Calls the callback with a read-write connection temporarily leased from the pool.
    func write(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> Void,
    ) async throws

    /// Invokes the callback with all connections leased from the pool.
    func withAllConnections(
        onConnection: @Sendable @escaping (
            _ writer: SQLiteConnectionLease,
            _ readers: [SQLiteConnectionLease]
        ) throws -> Void,
    ) async throws

    /// Closes the connection pool and associated resources.
    func close() async throws
}
