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
        // Don't start an explicit transaction, we do this internally.
        let (result, updates) = try await pool.writeWithoutTransaction { database in
            // This installs a temporary update hook, which breaks if GRDB had its own. Currently, we rely on
            // GRDB only installing update hooks for statements that need it (see https://github.com/groue/GRDB.swift/blob/36e30a6f1ef10e4194f6af0cff90888526f0c115/GRDB/Core/TransactionObserver.swift#L266-L275),
            // note that `statementObservations` is set in `statementWillExecute` and cleared after a statement
            // has completed or failed.
            // So since we have exclusive access to the write connection here, no GRDB-active statement can run and we
            // can safely install our own hooks.
            // In the future, we would like to use high-level GRDB APIs for this instead. However, we're blocked
            // by https://github.com/groue/GRDB.swift/issues/1863 on that.
            try collectWrites(db: database.sqliteConnection!) {
                try onConnection(GRDBConnectionLease(database: database))
            }
        }

        if !updates.isEmpty {
            tableUpdatesContinuation?.yield(updates)

            // Notify GRDB, this needs to be a write (transaction)
            try await pool.write { database in
                // Notify GRDB about these changes
                for table in updates {
                    try database.notifyChanges(in: Table(table))
                }
            }
        }
        return result
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
