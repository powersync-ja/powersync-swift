import Foundation
import GRDB
import PowerSync
import SQLite3

/// Adapts a GRDB `DatabasePool` for use with the PowerSync SDK.
///
/// This class implements `SQLiteConnectionPoolProtocol` and provides
/// integration between GRDB's connection pool and PowerSync's requirements,
/// including table update observation and direct access to SQLite connections.
///
/// - Provides async streams of table updates for replication.
/// - Bridges GRDB's managed connections to PowerSync's lease abstraction.
/// - Allows both read and write access to raw SQLite connections.
actor GRDBConnectionPool: SQLiteConnectionPoolProtocol {
    let pool: DatabasePool

    let tableUpdates: AsyncStream<Set<String>>
    private var tableUpdatesContinuation: AsyncStream<Set<String>>.Continuation?

    init(
        pool: DatabasePool
    ) {
        self.pool = pool
        // Cannot capture Self before initializing all properties
        var tempContinuation: AsyncStream<Set<String>>.Continuation?
        tableUpdates = AsyncStream { continuation in
            tempContinuation = continuation
            pool.add(
                transactionObserver: PowerSyncTransactionObserver { updates in
                    // push the update
                    continuation.yield(updates)
                },
                extent: .databaseLifetime
            )
        }
        tableUpdatesContinuation = tempContinuation
    }

    func read<T: Sendable>(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> T
    ) async throws -> T {
        return try await pool.read { database in
            try onConnection(
                GRDBConnectionLease(database: database)
            )
        }
    }

    func write<T: Sendable>(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> T
    ) async throws -> T {
        // Don't start an explicit transaction, we do this internally
        return try await pool.writeWithoutTransaction { database in
            return try onConnection(
                GRDBConnectionLease(database: database)
            )
        }
    }

    func withAllConnections<T: Sendable>(
        onConnection: @Sendable @escaping (SQLiteConnectionLease, [SQLiteConnectionLease]) throws -> T
    ) async throws -> T {
        // FIXME, we currently don't support updating the schema
        let result = try await pool.writeWithoutTransaction { database in
            let lease = try GRDBConnectionLease(database: database)
            let result = try onConnection(lease, [])
            database.clearSchemaCache()
            return result
        }
        pool.invalidateReadOnlyConnections()
        return result
    }

    func close() async throws {
        try pool.close()
    }
}
