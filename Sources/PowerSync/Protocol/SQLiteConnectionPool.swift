import Foundation

/// An implementation of a connection pool providing asynchronous access to a single writer and multiple readers.
/// This is the underlying pool implementation on which the higher-level PowerSync Swift SDK is built on.
public protocol SQLiteConnectionPoolProtocol {
    func getPendingUpdates() -> Set<String>

    /// Calls the callback with a read-only connection temporarily leased from the pool.
    func read(
        onConnection: @Sendable @escaping (OpaquePointer) -> Void,
    ) async throws

    /// Calls the callback with a read-write connection temporarily leased from the pool.
    func write(
        onConnection: @Sendable @escaping (OpaquePointer) -> Void,
    ) async throws

    /// Invokes the callback with all connections leased from the pool.
    func withAllConnections(
        onConnection: @Sendable @escaping (
            _ writer: OpaquePointer,
            _ readers: [OpaquePointer]
        ) -> Void,
    ) async throws

    /// Closes the connection pool and associated resources.
    func close() throws
}
