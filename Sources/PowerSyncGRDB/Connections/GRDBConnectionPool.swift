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

    func read(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> Void
    ) async throws {
        try await pool.read { database in
            try onConnection(
                GRDBConnectionLease(database: database)
            )
        }
    }

    func write(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> Void
    ) async throws {
        // Don't start an explicit transaction, we do this internally
        let result = try await pool.writeWithoutTransaction { database in
            guard let pointer = database.sqliteConnection else {
                throw PowerSyncGRDBError.connectionUnavailable
            }

            let sessionResult = try withSession(
                db: pointer,
            ) {
                try onConnection(
                    GRDBConnectionLease(database: database)
                )
            }

            return sessionResult
        }
        // Notify PowerSync of these changes
        tableUpdatesContinuation?.yield(result.affectedTables)
        // Notify GRDB, this needs to be a write (transaction)
        try await pool.write { database in
            // Notify GRDB about these changes
            for table in result.affectedTables {
                try database.notifyChanges(in: Table(table))
            }
        }

        if case let .failure(error) = result.blockResult {
            throw error
        }
    }

    func withAllConnections(
        onConnection: @Sendable @escaping (SQLiteConnectionLease, [SQLiteConnectionLease]) throws -> Void
    ) async throws {
        // FIXME, we currently don't support updating the schema
        try await pool.writeWithoutTransaction { database in
            let lease = try GRDBConnectionLease(database: database)
            try onConnection(lease, [])
        }
        pool.invalidateReadOnlyConnections()
    }

    func close() async throws {
        try pool.close()
    }
}
