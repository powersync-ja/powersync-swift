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
public final class GRDBConnectionPool: SQLiteConnectionPoolProtocol {
    let pool: DatabasePool

    public private(set) var tableUpdates: AsyncStream<Set<String>>
    private var tableUpdatesContinuation: AsyncStream<Set<String>>.Continuation?

    public init(
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

    public func processPowerSyncUpdates(_ updates: Set<String>) async throws {
        try await pool.write { database in
            for table in updates {
                try database.notifyChanges(in: Table(table))
                if table.hasPrefix("ps_data__") {
                    let stripped = String(table.dropFirst("ps_data__".count))
                    try database.notifyChanges(in: Table(stripped))
                } else if table.hasPrefix("ps_data_local__") {
                    let stripped = String(table.dropFirst("ps_data_local__".count))
                    try database.notifyChanges(in: Table(stripped))
                }
            }
        }
        // Pass the updates to the output stream
        tableUpdatesContinuation?.yield(updates)
    }

    public func read(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> Void
    ) async throws {
        try await pool.read { database in
            try onConnection(
                GRDBConnectionLease(database: database)
            )
        }
    }

    public func write(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) throws -> Void
    ) async throws {
        // Don't start an explicit transaction, we do this internally
        try await pool.writeWithoutTransaction { database in
            try onConnection(
                GRDBConnectionLease(database: database)
            )
        }
    }

    public func withAllConnections(
        onConnection _: @escaping (SQLiteConnectionLease, [SQLiteConnectionLease]) throws -> Void
    ) async throws {
        // TODO:
    }

    public func close() throws {
        try pool.close()
    }
}
