import Foundation

public protocol SQLiteConnectionLease {
    var pointer: OpaquePointer { get }
}

/// An implementation of a connection pool providing asynchronous access to a single writer and multiple readers.
/// This is the underlying pool implementation on which the higher-level PowerSync Swift SDK is built on.
public protocol SQLiteConnectionPoolProtocol {
    var tableUpdates: AsyncStream<Set<String>> { get }

    /// Calls the callback with a read-only connection temporarily leased from the pool.
    func read(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) -> Void,
    ) async throws

    /// Calls the callback with a read-write connection temporarily leased from the pool.
    func write(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) -> Void,
    ) async throws

    /// Invokes the callback with all connections leased from the pool.
    func withAllConnections(
        onConnection: @Sendable @escaping (
            _ writer: SQLiteConnectionLease,
            _ readers: [SQLiteConnectionLease]
        ) -> Void,
    ) async throws

    /// Closes the connection pool and associated resources.
    func close() throws
}
