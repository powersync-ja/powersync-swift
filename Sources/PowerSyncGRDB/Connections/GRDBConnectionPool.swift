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

    public func read(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) -> Void
    ) async throws {
        try await pool.read { database in
            try onConnection(
                GRDBConnectionLease(database: database)
            )
        }
    }

    public func write(
        onConnection: @Sendable @escaping (SQLiteConnectionLease) -> Void
    ) async throws {
        // Don't start an explicit transaction, we do this internally
        let updateBroker = UpdateBroker()
        try await pool.writeWithoutTransaction { database in

            let brokerPointer = Unmanaged.passUnretained(updateBroker).toOpaque()

            /// GRDB only registers an update hook if it detects a requirement for one.
            /// It also removes its own update hook if no longer needed.
            /// We use the SQLite connection pointer directly, which sidesteps GRDB.
            /// We can register our own temporary update hook here.
            let previousParamPointer = sqlite3_update_hook(
                database.sqliteConnection,
                { brokerPointer, _, _, tableNameCString, _ in
                    let broker = Unmanaged<UpdateBroker>.fromOpaque(brokerPointer!).takeUnretainedValue()
                    broker.updates.insert(String(cString: tableNameCString!))
                },
                brokerPointer
            )

            // This should not be present
            assert(previousParamPointer == nil, "A pre-existing update hook was already registered and has been overwritten.")

            defer {
                // Deregister our temporary hook
                sqlite3_update_hook(database.sqliteConnection, nil, nil)
            }

            try onConnection(
                GRDBConnectionLease(database: database)
            )
        }

        // Notify GRDB consumers of updates
        // Seems like we need to do this in a write transaction
        try await pool.write { database in
            for table in updateBroker.updates {
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
        guard let pushUpdates = tableUpdatesContinuation else {
            return
        }
        // Notify the PowerSync SDK consumers of updates
        pushUpdates.yield(updateBroker.updates)
    }

    public func withAllConnections(
        onConnection _: @escaping (SQLiteConnectionLease, [SQLiteConnectionLease]) -> Void
    ) async throws {
        // TODO:
    }

    public func close() throws {
        try pool.close()
    }
}
