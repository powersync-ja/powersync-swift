import CSQLite
import DequeModule
import Foundation

enum DatabaseLocation {
    case inMemory
    case inDefaultDirectory(name: String)
    case atPath(String)

    /// The on-disk path other processes can share, or `nil` for in-memory databases.
    var sharedPath: String? {
        switch self {
        case .inMemory:
            return nil
        case let .inDefaultDirectory(name):
            return (try? DatabaseLocation.appleDefaultDatabaseDirectory().path).map { "\($0)/\(name)" }
        case let .atPath(path):
            return path
        }
    }

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
        case .atPath(let absolutePath):
            let fileManager = FileManager.default
            let directory = (absolutePath as NSString).deletingLastPathComponent

            if !fileManager.fileExists(atPath: directory) {
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }

            path = absolutePath
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
    private let opener = PoolOpener()
    /// Cross-process change signaling; `nil` for in-memory databases (nothing to share).
    private let changeSignal: CrossProcessChangeSignal?

    init(location: DatabaseLocation, logger: any LoggerProtocol, initialStatements: [String] = []) {
        self.location = location
        self.logger = logger
        self.initialStatements = initialStatements
        self.changeSignal = location.sharedPath.map {
            CrossProcessChangeSignal(databasePath: $0, logger: logger)
        }
    }

    var tableUpdates: AsyncStream<Set<String>> {
        tableUpdatesStream.subscribe()
    }

    /// Asyncifies a synchronous unit of work on by running it on a suitable background thread.
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

        // The busy handler is installed first so later statements wait instead of failing,
        // but note it does NOT apply to the WAL transition below.
        let _ = try context.execute(sql: "pragma busy_timeout = 30000", parameters: [])

        if isWriter {
            let _ = try context.execute(sql: "pragma journal_mode = WAL", parameters: [])
        }

        let _ = try context.execute(sql: "pragma journal_size_limit = \(6 * 1024 * 1024)", parameters: [])
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

    /// Whether an error from opening/configuring a connection is transient contention
    /// (another process holds the file, e.g. mid WAL-recovery) and worth retrying.
    /// `pragma journal_mode = WAL` reports SQLITE_BUSY/SQLITE_BUSY_RECOVERY without
    /// consulting the busy handler, so `busy_timeout` cannot cover the open path.
    private static func isTransientOpenError(_ error: any Error) -> Bool {
        guard case let PowerSyncError.sqliteError(extendedResultCode, _, _, _, _) = error else {
            return false
        }
        let primary = extendedResultCode & 0xFF
        return primary == SQLITE_BUSY || primary == SQLITE_LOCKED
    }

    /// Opens and configures a connection, retrying with backoff while another process
    /// holds the database (apps and their widgets/extensions open concurrently).
    fileprivate func openConfiguredConnection(writer: Bool) throws -> RawSqliteConnection {
        // ~5s total budget: 10ms doubling to a 250ms cap. Concurrent opens (app + widget)
        // resolve in tens of milliseconds; a database still busy after seconds is stuck.
        var delayMicroseconds: UInt32 = 10_000
        let deadline = DispatchTime.now() + .seconds(5)
        while true {
            do {
                let connection = try location.openConnection(writer: writer)
                try configureConnection(connection: connection, isWriter: writer)
                return connection
            } catch where Self.isTransientOpenError(error) && DispatchTime.now() < deadline {
                // The failed connection is dropped (closed by deinit); reopen fresh.
                logger.debug(
                    "database busy while opening (another process holds it); retrying in \(delayMicroseconds / 1000)ms",
                    tag: "AsyncConnectionPool"
                )
                usleep(delayMicroseconds)
                delayMicroseconds = min(delayMicroseconds * 2, 250_000)
            }
        }
    }

    /// Opens connections on a background thread to obtain the native connection pool.
    private func obtainInner() async throws -> NativeConnectionPool {
        try await opener.obtainPool(pool: self)
    }

    func read<T>(onConnection: @escaping @Sendable (any SQLiteConnectionLease) throws -> T) async throws -> T {
        let pool = try await obtainInner()
        return try await pool.read { connection in
            return try await runBlocking { try onConnection(connection) }
        }
    }

    func write<T>(onConnection: @escaping @Sendable (any SQLiteConnectionLease) throws -> T) async throws -> T {
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
        changeSignal?.stop()
        try await self.opener.close()
    }

    private actor PoolOpener {
        private var pool: NativeConnectionPool? = nil
        private var isClosed = false

        func obtainPool(pool context: AsyncConnectionPool) async throws -> NativeConnectionPool {
            if let pool {
                return pool
            }

            try registerPowerSyncCoreExtension()
            let handleUpdates: @Sendable (_: Set<String>) -> () = { [weak context] updates in
                context?.tableUpdatesStream.dispatch(event: updates)
                // Tell other processes sharing this file that tables changed.
                context?.changeSignal?.post()
            }
            context.changeSignal?.start { [weak context] in
                // Another process (or this one; harmless, throttled downstream) changed
                // the database outside this pool's update hooks.
                context?.tableUpdatesStream.dispatch(event: [EXTERNAL_CHANGES_MARKER])
            }

            let pool = try await context.runBlocking {
                let writer = try context.openConfiguredConnection(writer: true)

                if case .inMemory = context.location {
                    return NativeConnectionPool(singleConnection: writer, logger: context.logger, handleUpdates: handleUpdates)
                } else {
                    let numReaders = 4
                    var readers = RigidDeque<RawSqliteConnection>(capacity: numReaders)
                    while !readers.isFull {
                        readers.append(try context.openConfiguredConnection(writer: false))
                    }

                    return NativeConnectionPool(writer: writer, readers: readers, logger: context.logger, handleUpdates: handleUpdates)
                }
            }

            self.pool = pool
            return pool
        }

        func close() async throws {
            if isClosed {
                return
            }

            isClosed = true
            if let pool {
                try await pool.close()
            }
        }
    }
}
