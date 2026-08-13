import CSQLite
import DequeModule
import Foundation

enum DatabaseLocation {
    case inMemory
    case inDefaultDirectory(name: String)
    case atPath(String)

    /// The on-disk path other processes can share, or `nil` when the database can't be
    /// shared. Only absolute paths (typically an App Group container) are shareable; the
    /// default directory is inside the app's own sandbox, which extensions cannot reach.
    var sharedPath: String? {
        switch self {
        case .inMemory, .inDefaultDirectory:
            return nil
        case let .atPath(path):
            return path
        }
    }

    func openConnection(writer: Bool) throws -> RawSqliteConnection {
        switch self {
        case .inMemory:
            return try DatabaseLocation.open(path: ":memory:", flags: SQLITE_OPEN_READWRITE)
        case let .inDefaultDirectory(name):
            let directory = (try DatabaseLocation.appleDefaultDatabaseDirectory()).path
            return try DatabaseLocation.openFile(at: "\(directory)/\(name)", in: directory, writer: writer)
        case let .atPath(absolutePath):
            let directory = (absolutePath as NSString).deletingLastPathComponent
            return try DatabaseLocation.openFile(at: absolutePath, in: directory, writer: writer)
        }
    }

    /// Creates `directory` if needed, then opens the database file with the right flags.
    private static func openFile(at path: String, in directory: String, writer: Bool) throws -> RawSqliteConnection {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory) {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let flags = writer ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) : SQLITE_OPEN_READONLY
        return try open(path: path, flags: flags)
    }

    private static func open(path: String, flags: Int32) throws -> RawSqliteConnection {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
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

        // `isDirectory: true` avoids a blocking stat to infer the URL kind.
        return documentsDirectory.appendingPathComponent("databases", isDirectory: true)
    }
}

/// Wraps an ``NativeConnectionPool`` to handle opening connections and to dispatch database tasks in a suitable queue.
final class AsyncConnectionPool: SQLiteConnectionPoolProtocol {
    private let location: DatabaseLocation
    private let initialStatements: [String]
    private let logger: any LoggerProtocol
    private let tableUpdatesStream = BroadcastStream<Set<String>>()
    private let opener = PoolOpener()
    /// Set for databases other processes can open, in which case writes are announced through
    /// ``CrossProcessUpdateLog`` and this pool reacts to the other processes' rows.
    ///
    /// Note that this covers any absolute path, not just App Group containers, since sharing
    /// cannot be detected from the path alone.
    private let updateLog: CrossProcessUpdateLog?

    init(location: DatabaseLocation, logger: any LoggerProtocol, initialStatements: [String] = []) {
        self.location = location
        self.logger = logger
        self.initialStatements = initialStatements
        self.updateLog = location.sharedPath.map {
            CrossProcessUpdateLog(
                signal: CrossProcessChangeSignal(databasePath: $0, logger: logger),
                logger: logger
            )
        }
    }

    /// Tracks the highest consumed update-log row id and when the log was last read, so a
    /// long read gap (a suspended process) can be distinguished from steady-state reads.
    private struct ReadState {
        var watermark: Int64 = 0
        var lastReadAt: Date?
    }

    private let readState = Mutex(ReadState())
    /// Notifications from other processes, consumed by ``startReadingUpdateLog()``.
    private let updateNotifications = BroadcastStream<Void>()
    private let updateLogReader = Mutex<Task<Void, Never>?>(nil)

    /// Minimum spacing between update-log reads. Notifications arriving while we read or wait
    /// are merged into a single further read, so a burst of writes cannot become a burst of
    /// reads. Cross-process latency is not critical: a process sees its own writes immediately.
    private static let readThrottleSeconds: TimeInterval = 0.25

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
        let context = try connection.asLease()
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

            // Create the update log before any write can try to record into it (the
            // `powersync_init()` write during initialization is the first one).
            if updateLog != nil {
                let _ = try context.execute(sql: CrossProcessUpdateLog.createTableSQL, parameters: [])
            }
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

    /// Opens and configures all connections of the pool in a single blocking unit of work.
    /// One attempt: `RawSqliteConnection` is `~Copyable` and cannot cross the async
    /// boundary, so the whole pool is built here and the retry/backoff lives in the async
    /// caller (``buildPoolWithRetry(handleUpdates:)``).
    fileprivate func buildPool(handleUpdates: @escaping @Sendable (Set<String>) -> Void) throws -> NativeConnectionPool {
        let writer = try location.openConnection(writer: true)
        try configureConnection(connection: writer, isWriter: true)

        if case .inMemory = location {
            return NativeConnectionPool(singleConnection: writer, logger: logger, updateLog: updateLog, handleUpdates: handleUpdates)
        }
        let numReaders = 4
        var readers = RigidDeque<RawSqliteConnection>(capacity: numReaders)
        while !readers.isFull {
            let reader = try location.openConnection(writer: false)
            try configureConnection(connection: reader, isWriter: false)
            readers.append(reader)
        }
        return NativeConnectionPool(writer: writer, readers: readers, logger: logger, updateLog: updateLog, handleUpdates: handleUpdates)
    }

    /// Builds the pool, retrying with asynchronous backoff while another process holds the
    /// database (apps and their widgets/extensions open concurrently). Awaiting between
    /// attempts pins no thread and is cancellable, unlike a blocking sleep.
    private func buildPoolWithRetry(handleUpdates: @escaping @Sendable (Set<String>) -> Void) async throws -> NativeConnectionPool {
        // ~5s total budget: 10ms doubling to a 250ms cap. Concurrent opens (app + widget)
        // resolve in tens of milliseconds; a database still busy after seconds is stuck.
        // `Task.sleep(nanoseconds:)` keeps the package's iOS 15 / macOS 12 floor while
        // staying async and cancellable.
        var delayNanoseconds: UInt64 = 10_000_000
        let deadline = DispatchTime.now() + .seconds(5)
        while true {
            do {
                return try await runBlocking { try self.buildPool(handleUpdates: handleUpdates) }
            } catch where Self.isTransientOpenError(error) && DispatchTime.now() < deadline {
                logger.debug(
                    "database busy while opening (another process holds it); retrying in \(delayNanoseconds / 1_000_000)ms",
                    tag: "AsyncConnectionPool"
                )
                try await Task.sleep(nanoseconds: delayNanoseconds)
                delayNanoseconds = min(delayNanoseconds * 2, 250_000_000)
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

    /// Reads the update log whenever another process signals, merging notifications that arrive
    /// while a read is in progress (or during the throttle that follows) into a single re-read,
    /// the same way `watch` queries throttle table updates.
    ///
    /// The task lives as long as the pool does and is cancelled in ``close()``. It is detached
    /// because it belongs to the pool and not to whichever caller happened to open it: that
    /// caller's priority, task locals and cancellation must not reach this loop.
    private func startReadingUpdateLog() {
        let notifications = updateNotifications.subscribe()
        let task = Task.detached { [weak self] in
            let merged = MergeItemSequence(inner: notifications)
            do {
                for try await _ in merged {
                    guard let self else { return }
                    await self.performUpdateLogRead()
                    try await sleepForSeconds(seconds: Self.readThrottleSeconds)
                }
            } catch {
                // Cancelled while reading or waiting; nothing left to do.
            }
        }
        updateLogReader.withLock { $0 = task }
    }

    /// Rows written by this pool are skipped, so a notification caused by our own write finds
    /// nothing to do. Falls back to ``EXTERNAL_CHANGES_MARKER``, which re-runs every watch, when
    /// the precise tables may be incomplete: a read error, an undecodable payload, or a read gap
    /// long enough that rows we needed could have been pruned (a suspended process).
    private func performUpdateLogRead() async {
        guard let updateLog else { return }

        let (since, gap) = readState.withLock { state in
            (state.watermark, state.lastReadAt.map(Date().timeIntervalSince))
        }
        // Rows are only pruned once they are older than the retention window, so having read
        // within that window proves nothing we still need was pruned. A longer gap does not
        // mean we lost anything (an idle database prunes nothing either, since pruning happens
        // on writes), but we cannot tell, so we re-query everything once and then go back to
        // precise updates.
        let mightHaveMissed = gap.map { $0 > Double(CrossProcessUpdateLog.retentionSeconds) } ?? true

        do {
            let author = updateLog.author
            let result: (tables: Set<String>, maxSeen: Int64?, decodeFailed: Bool) = try await read { connection in
                var tables = Set<String>()
                var maxSeen: Int64?
                var decodeFailed = false
                try connection.withIterator(
                    sql: CrossProcessUpdateLog.readSQL,
                    parameters: [.int64(since), .int64(author)],
                    callback: { rows in
                        while let row = try rows.next(callback: CrossProcessUpdateLog.readRow) {
                            maxSeen = row.id
                            if let decoded = try? JSONDecoder().decode([String].self, from: Data(row.tables.utf8)) {
                                tables.formUnion(decoded)
                            } else {
                                decodeFailed = true
                            }
                        }
                    }
                )
                return (tables, maxSeen, decodeFailed)
            }

            readState.withLock { state in
                if let maxSeen = result.maxSeen, maxSeen > state.watermark {
                    state.watermark = maxSeen
                }
                state.lastReadAt = Date()
            }

            if mightHaveMissed || result.decodeFailed {
                tableUpdatesStream.dispatch(event: [EXTERNAL_CHANGES_MARKER])
            } else if !result.tables.isEmpty {
                tableUpdatesStream.dispatch(event: result.tables)
            }
        } catch {
            // Reading failed (including when the pool is closing), so we cannot tell which
            // tables changed: conservatively re-query everything.
            tableUpdatesStream.dispatch(event: [EXTERNAL_CHANGES_MARKER])
        }
    }

    func close() async throws {
        // Only stop update notifications after the async close, since that can be cancelled.
        try await self.opener.close()
        updateLog?.signal.stop()
        updateLogReader.withLock { reader in
            reader?.cancel()
            reader = nil
        }
    }

    private actor PoolOpener {
        private var pool: NativeConnectionPool? = nil

        func obtainPool(pool context: AsyncConnectionPool) async throws -> NativeConnectionPool {
            if let pool {
                return pool
            }

            try registerPowerSyncCoreExtension()
            let handleUpdates: @Sendable (_: Set<String>) -> () = { [weak context] updates in
                context?.tableUpdatesStream.dispatch(event: updates)
            }

            let pool = try await context.buildPoolWithRetry(handleUpdates: handleUpdates)
            self.pool = pool

            // Listen only once the pool exists, so a notification arriving while we open cannot
            // re-enter this actor and build a second pool.
            context.readState.withLock { $0.lastReadAt = Date() }
            if context.updateLog != nil {
                context.startReadingUpdateLog()
                context.updateLog?.signal.start { [weak context] in
                    context?.updateNotifications.dispatch(event: ())
                }
            }

            return pool
        }

        func close() async throws {
            if let pool {
                try await pool.close()
            }
        }
    }
}
