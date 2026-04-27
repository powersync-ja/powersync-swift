import CSQLite
import DequeModule
import Foundation

enum DatabaseLocation {
    case inMemory
    case inDefaultDirectory(name: String)
    
    func openConnection(writer: Bool) throws -> RawSqliteConnection {
        var db: OpaquePointer?
        let rc: Int32
        let path: String
        
        switch self {
        case .inMemory:
            path = ":memory:"
            rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        case .inDefaultDirectory(let name):
            let fileManager = FileManager.default
            let databaseDirectory = (try DatabaseLocation.appleDefaultDatabaseDirectory()).path
            
            if !fileManager.fileExists(atPath: databaseDirectory) {
                try fileManager.createDirectory(atPath: databaseDirectory, withIntermediateDirectories: true)
            }

            path = "\(databaseDirectory)/\(name)"
            let flags = if writer {
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            } else {
                SQLITE_OPEN_READONLY
            }
            rc = sqlite3_open_v2(path, &db, flags, nil)
        }

        if rc != 0 {
            throw PowerSyncError.sqliteError(extendedResultCode: rc, offset: nil, message: "Could not open database \(path)", errorString: nil, sql: nil)
        }

        return RawSqliteConnection(connection: db!)
    }

    /// This returns the default directory in which we store SQLite database files.
    static func appleDefaultDatabaseDirectory() throws -> URL {
        let fileManager = FileManager.default

        // Get the application support directory
        guard let documentsDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PowerSyncError.operationFailed(message: "Unable to find application support directory")
        }

        return documentsDirectory.appendingPathComponent("databases")
    }
}

/// Wraps an ``NativeConnectionPool`` to handle opening connections and to dispatch database tasks in a suitable queue.
final class AsyncConnectionPool: SQLiteConnectionPoolProtocol {
    private let location: DatabaseLocation
    private let initialStatements: [String]
    private let logger: any LoggerProtocol
    private let tableUpdatesStream = BroadcastStream<Set<String>>()
    private let inner: AsyncSemaphore<NativeConnectionPool?> = AsyncSemaphore(singleElement: nil)

    init(location: DatabaseLocation, logger: any LoggerProtocol, initialStatements: [String] = []) {
        self.location = location
        self.logger = logger
        self.initialStatements = initialStatements
    }
    
    var tableUpdates: AsyncStream<Set<String>> {
        tableUpdatesStream.subscribe()
    }
    
    private func runBlocking<T>(action: @escaping @Sendable () throws -> T, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result(catching: { try action() }))
            }
        }
    }
    
    private func configureConnection(connection: borrowing RawSqliteConnection, isWriter: Bool) throws {
        let context = connection.asLease()
        for stmt in initialStatements {
            let _ = try context.execute(sql: stmt, parameters: [])
        }

        if isWriter {
            let _ = try context.execute(sql: "pragma journal_mode = WAL", parameters: [])
        } else {
            // This is mainly an additional safety element, we also open read connections SQLITE_READONLY.
            let _ = try context.execute(sql: "pragma query_only = TRUE", parameters: [])
        }

        let _ = try context.execute(sql: "pragma journal_size_limit = \(6 * 1024 * 1024)", parameters: [])
        let _ = try context.execute(sql: "pragma busy_timeout = 30000", parameters: [])
        let _ = try context.execute(sql: "pragma cache_size = -\(50 * 1024)", parameters: [])

        if isWriter {
            // Older versions of the SDK used to set up an empty schema and raise the user version to 1.
            // Keep doing that for consistency.
            let version = try context.withIterator(sql: "pragma user_version", parameters: []) { rows in
                try rows.next { try $0.getInt(index: 0) }
            }
            if let version, version < 1 {
                let _ = try context.execute(sql: "pragma user_version = 1", parameters: [])
            }

            let _ = try context.execute(sql: "select powersync_update_hooks('install')", parameters: [])
        }
    }
    
    private func obtainInner() async throws -> NativeConnectionPool {
        var lease = try await inner.acquire(count: 1)
        if let pool = lease.acquiredItems[0] {
            return pool
        } else {
            try registerPowerSyncCoreExtension()

            @Sendable func handleUpdates(_ updates: Set<String>) {
                self.tableUpdatesStream.dispatch(event: updates)
            }
            
            let pool = try await runBlocking { [self] in
                let writer = try location.openConnection(writer: true)
                try configureConnection(connection: writer, isWriter: true)

                if case .inMemory = location {
                    return NativeConnectionPool(singleConnection: writer, logger: logger, handleUpdates: handleUpdates)
                } else {
                    let numReaders = 4
                    var readers = RigidDeque<RawSqliteConnection>(capacity: numReaders)
                    while !readers.isFull {
                        let connection = try location.openConnection(writer: false)
                        try configureConnection(connection: connection, isWriter: false)
                        readers.append(connection)
                    }

                    return NativeConnectionPool(writer: writer, readers: readers, logger: logger, handleUpdates: handleUpdates)
                }
            }
            
            lease.acquiredItems[0] = pool
            return pool
        }
    }

    func read<T>(onConnection: @escaping @Sendable (any SQLiteConnectionLease) throws -> T) async throws -> T {
        let pool = try await obtainInner()
        return try await pool.read { connection in
            return try await runBlocking { try onConnection(connection) }
        }
    }

    func write<T>(onConnection: @escaping @Sendable (any SQLiteConnectionLease) throws -> T) async throws -> T{
        let pool = try await obtainInner()
        return try await pool.write { connection in
            try await runBlocking { try onConnection(connection) }
        }
    }
    
    func withAllConnections<T>(onConnection: @escaping @Sendable (any SQLiteConnectionLease, [any SQLiteConnectionLease]) throws -> T) async throws -> T {
        let pool = try await obtainInner()
        return try await pool.withAllConnections { writer, readers in
            try await runBlocking { try onConnection(writer, readers) }
        }
    }

    func close() async throws {
        var lease = try await inner.acquire(count: 1)
        if let pool = lease.acquiredItems[0] {
            try await pool.close()
            lease.acquiredItems[0] = nil
        }
    }
}
