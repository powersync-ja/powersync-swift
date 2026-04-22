import AsyncAlgorithms
import Foundation

final class PowerSyncDatabaseImpl: PowerSyncDatabaseProtocol {
    let logger: any LoggerProtocol
    let syncCoordinator = SyncCoordinator()
    let syncStatus = SwiftSyncStatus()
    private let dbFilename: String?
    private let httpClient: HttpClient
    private let initializer = DatabaseInitizalizationActor()
    fileprivate let pool: any SQLiteConnectionPoolProtocol
    let schema: AsyncMutex<Schema>

    init(
        dbFilename: String? = nil,
        logger: any LoggerProtocol,
        pool: any SQLiteConnectionPoolProtocol,
        httpClient: HttpClient,
        schema: Schema
    ) {
        self.dbFilename = dbFilename
        self.logger = logger
        self.schema = AsyncMutex(schema)
        self.httpClient = httpClient
        self.pool = pool
    }
    
    var currentStatus: any SyncStatus {
        syncStatus
    }

    func resolveOfflineSyncStatusIfNotConnected() async throws {
        try await syncCoordinator.guardNotConnected(inner: {
            try await resolveOfflineSyncStatus()
        }, ifConnected: {})
    }
    
    private func initialize() async throws {
        try await initializer.ensureInitialized(db: self)
    }
    
    fileprivate func resolveOfflineSyncStatus() async throws {
        // We can't use get() here because it runs as part of the initialization step.
        let offlineSyncStatus = try await poolRead(pool) { connection in
            try connection.get(sql: "SELECT powersync_offline_sync_status()", parameters: []) { cursor in
                let raw = try cursor.getString(index: 0)
                return try StreamingSyncClient.jsonDecoder.decode(CoreDownloadSyncStatus.self, from: raw.data(using: .utf8)!)
            }
        }

        syncStatus.mutateStatus { $0 = MutableSyncStatus(core: offlineSyncStatus) }
    }

    func updateSchema(schema: any SchemaProtocol) async throws {
        try await initializer.ensureInitialized(db: self)
        try await syncCoordinator.guardNotConnected(
            inner: {
                let schema = Schema(other: schema)
                await self.schema.withMutex { $0 = schema }
                try await applySchema(schema: schema)
            },
            ifConnected: { throw PowerSyncError.operationFailed(message: "Cannot update schema while connected") }
        )
    }
    
    fileprivate func applySchema(schema: Schema) async throws {
        try await poolWithAll(pool) { writer, readers in
            let encoded = try StreamingSyncClient.jsonEncoder.encode(schema)
            guard let asString = String(data: encoded, encoding: .utf8) else {
                throw PowerSyncError.operationFailed(message: "Could not serialize schema")
            }
            try writer.execute(sql: "SELECT powersync_replace_schema(?)", parameters: [asString])

            for reader in readers {
                // Update the schema on all read connections
                try reader.execute(sql: "pragma table_info('sqlite_master')", parameters: [])
            }
        }
    }

    func waitForFirstSync() async throws {
        try await initialize()
        await syncStatus.waitFor { $0.hasSynced == true }
    }
    
    func waitForFirstSync(priority: Int32) async throws {
        try await initialize()
        let priority = BucketPriority(priority)
        await syncStatus.waitFor { $0.statusForPriority(priority).hasSynced == true }
    }

    func getPowerSyncVersion() async throws -> String {
        try await initialize()
        // Set during initialization
        return await initializer.powerSyncVersion!
    }
    
    func disconnect() async throws {
        await syncCoordinator.disconnect()
    }
    
    func syncStream(name: String, params: JsonParam?) -> any SyncStream {
        PendingSyncStream(db: self, name: name, parameters: params)
    }
    
    func close() async throws {
        try await initialize()
        try await initializer.close {
            await syncCoordinator.disconnect()
            try await pool.close()
        }
    }
    
    func close(deleteDatabase: Bool) async throws {
        try await close()
        if deleteDatabase {
            try await self.deleteDatabase()
        }
    }

    private func deleteDatabase() async throws {
        if let dbFilename {
            // We can use the supplied dbLocation when we support that in future
            let directory = try DatabaseLocation.appleDefaultDatabaseDirectory()
            let fileManager = FileManager.default
            
            // SQLite files to delete:
            // 1. Main database file: dbFilename
            // 2. WAL file: dbFilename-wal
            // 3. SHM file: dbFilename-shm
            // 4. Journal file: dbFilename-journal (for rollback journal mode, though WAL mode typically doesn't use it)

            let filesToDelete = [
                dbFilename,
                "\(dbFilename)-wal",
                "\(dbFilename)-shm",
                "\(dbFilename)-journal"
            ]
            
            for filename in filesToDelete {
                let fileUrl = directory.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: fileUrl.path) {
                    try fileManager.removeItem(at: fileUrl)
                }
            }
        }
    }
    
    func connect(connector: any PowerSyncBackendConnectorProtocol, options: ConnectOptions?) async throws {
        await syncCoordinator.connect(db: self, connector: connector, options: options ?? ConnectOptions(), client: httpClient)
    }
    
    func watch<RowType>(options: WatchOptions<RowType>) throws -> AsyncThrowingStream<[RowType], any Error> {
        AsyncThrowingStream { continuation in
            // Create an outer task to monitor cancellation
            let task = Task {
                do {
                    try await initialize()
                    let watchedTables = try await self.getQuerySourceTables(
                        sql: options.sql,
                        parameters: options.parameters
                    )

                    let updateNotifications = pool.tableUpdates.filter { changedTables in
                        changedTables.contains(where: watchedTables.contains)
                    }.map { _ in () }
                    // Allows emitting the first result even if there aren't changes
                    let withInitial = AsyncAlgorithms.merge([()].async, updateNotifications)
                    let throttled = AsyncThrottleSequence(inner: withInitial, duration: options.throttle)

                    for try await _ in throttled {
                        // Check if the outer task is cancelled
                        try Task.checkCancellation()

                        try continuation.yield(await self.getAll(
                            sql: options.sql,
                            parameters: options.parameters,
                            mapper: options.mapper
                        ))
                    }

                    continuation.finish()
                } catch {
                    if error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            // Propagate cancellation from the outer task to the inner task
            continuation.onTermination = { @Sendable _ in
                task.cancel() // This cancels the inner task when the stream is terminated
            }
        }
    }
    
    func watch<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @escaping @Sendable (any SqlCursor) throws -> RowType) throws -> AsyncThrowingStream<[RowType], any Error> {
        return try watch(options: WatchOptions(sql: sql, parameters: parameters, mapper: mapper))
    }
    
    func disconnectAndClear(clearLocal: Bool, soft: Bool) async throws {
        try await initialize()
        try await syncCoordinator.disconnectAndThen {
            var flags = 0
            if clearLocal {
                flags |= 1
            }
            if soft {
                flags |= 2
            }
            
            do {
                let flags = flags
                let _ = try await poolWrite(pool) { ctx in try ctx.execute(sql: "SELECT powersync_clear(?)", parameters: [flags]) }
            }
        }
    }
    
    func writeLock<R>(callback: @escaping @Sendable (any ConnectionContext) throws -> R) async throws -> R {
        try await initialize()
        return try await poolWrite(pool, action: callback)
    }
    
    func readLock<R>(callback: @escaping @Sendable (any ConnectionContext) throws -> R) async throws -> R {
        try await initialize()
        return try await poolRead(pool, action: callback)
    }
    
    func writeTransaction<R>(callback: @escaping @Sendable (any Transaction) throws -> R) async throws -> R {
        return try await writeLock { ctx in try TransactionImpl.run(conn: ctx, callback: callback) }
    }
    
    func readTransaction<R>(callback: @escaping @Sendable (any Transaction) throws -> R) async throws -> R {
        return try await readLock { ctx in try TransactionImpl.run(conn: ctx, callback: callback) }
    }

    private func getQuerySourceTables(
        sql: String,
        parameters: [Sendable?]
    ) async throws -> Set<String> {
        let rows = try await getAll(
            sql: "EXPLAIN \(sql)",
            parameters: parameters,
            mapper: { cursor in
                try ExplainQueryResult(
                    addr: cursor.getString(index: 0),
                    opcode: cursor.getString(index: 1),
                    p1: cursor.getInt64(index: 2),
                    p2: cursor.getInt64(index: 3),
                    p3: cursor.getInt64(index: 4)
                )
            }
        )

        let rootPages = rows.compactMap { row in
            if (row.opcode == "OpenRead" || row.opcode == "OpenWrite") &&
                row.p3 == 0 && row.p2 != 0
            {
                return row.p2
            }
            return nil
        }

        do {
            let pagesData = try StreamingSyncClient.jsonEncoder.encode(rootPages)
            guard let pagesString = String(data: pagesData, encoding: .utf8) else {
                throw PowerSyncError.operationFailed(
                    message: "Failed to convert pages data to UTF-8 string"
                )
            }

            let tableRows = try await getAll(
                sql: "SELECT tbl_name FROM sqlite_master WHERE rootpage IN (SELECT json_each.value FROM json_each(?))",
                parameters: [
                    pagesString,
                ]
            ) { try $0.getString(index: 0) }

            return Set(tableRows)
        } catch {
            throw PowerSyncError.operationFailed(
                message: "Could not determine watched query tables",
                underlyingError: error
            )
        }
    }
    
    static let maxOpId = Int64.max
}

private struct ExplainQueryResult {
    let addr: String
    let opcode: String
    let p1: Int64
    let p2: Int64
    let p3: Int64
}

private actor DatabaseInitizalizationActor {
    private var isInitialized = false
    var powerSyncVersion: String?
    private var closed = false
    
    func ensureInitialized(db: PowerSyncDatabaseImpl) async throws {
        if closed {
            throw PowerSyncError.operationFailed(message: "Attempted to use closed PowerSync database")
        }
        if isInitialized {
            return
        }

        powerSyncVersion = try await poolWrite(db.pool) { conn in
            let sqliteVersion = try conn.get(sql: "SELECT sqlite_version()", parameters: []) { try $0.getString(index: 0) }
            let powerSyncVersion = try conn.get(sql: "SELECT powersync_rs_version()", parameters: []) { try $0.getString(index: 0) }

            db.logger.debug("Opened connection. SQLite version \(sqliteVersion), PowerSync SQLite core extension \(powerSyncVersion)", tag: "PowerSyncDatabase")

            try conn.execute(sql: "SELECT powersync_init()", parameters: [])
            return powerSyncVersion
        }

        try await db.applySchema(schema: db.schema.withMutex { $0 })
        try await db.resolveOfflineSyncStatus()
        isInitialized = true
    }
    
    func close(action: () async throws -> ()) async rethrows {
        if !closed {
            closed = true
            try await action()
        }
    }
}
