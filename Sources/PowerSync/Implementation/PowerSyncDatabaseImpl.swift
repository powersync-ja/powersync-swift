import AsyncAlgorithms
import Foundation

final class PowerSyncDatabaseImpl: PowerSyncDatabaseProtocol {
    let logger: any LoggerProtocol
    let group: ActiveDatabaseGroup
    let syncStatus = SwiftSyncStatus()
    private let dbFilename: String?
    private let httpClient: HttpClient
    private let initializer = DatabaseInitializationAction()
    let pool: any SQLiteConnectionPoolProtocol
    let schema: AsyncMutex<Schema>

    init(
        dbFilename: String? = nil,
        identifier: String,
        activeInstanceStore: DatabaseGroupCollection = .shared,
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
        self.group = activeInstanceStore.referenceGroup(identifier: identifier, logger: logger)
    }

    var currentStatus: any SyncStatus {
        syncStatus
    }

    func resolveOfflineSyncStatusIfNotConnected() async throws {
        try await group.syncCoordinator.guardNotConnected(inner: {
            try await resolveOfflineSyncStatus()
        }, ifConnected: {})
    }
    
    private func initialize() async throws {
        try await initializer.ensureInitialized(db: self)
    }
    
    fileprivate func resolveOfflineSyncStatus() async throws {
        // We can't use get() here because it runs as part of the initialization step.
        let offlineSyncStatus = try await readLockInner { connection in
            try connection.get(sql: "SELECT powersync_offline_sync_status()", parameters: []) { cursor in
                let raw = try cursor.getString(index: 0)
                guard let data = raw.data(using: .utf8) else {
                    throw PowerSyncError.operationFailed(message: "Could not encode offline sync status")
                }
                return try StreamingSyncClient.jsonDecoder.decode(CoreDownloadSyncStatus.self, from: data)
            }
        }

        syncStatus.mutateStatus { $0 = MutableSyncStatus(core: offlineSyncStatus) }
    }

    func updateSchema(schema: any SchemaProtocol) async throws {
        try await initializer.ensureInitialized(db: self)
        try await group.syncCoordinator.guardNotConnected(
            inner: {
                let schema = Schema(other: schema)
                await self.schema.withMutex { $0 = schema }
                try await applySchema(schema: schema)
            },
            ifConnected: { throw PowerSyncError.operationFailed(message: "Cannot update schema while connected") }
        )
    }
    
    fileprivate func applySchema(schema: Schema) async throws {
        try await pool.withAllConnections { writer, readers in
            let encoded = try StreamingSyncClient.jsonEncoder.encode(schema)
            guard let asString = String(data: encoded, encoding: .utf8) else {
                throw PowerSyncError.operationFailed(message: "Could not serialize schema")
            }

            let _ = try writer.execute(sql: "SELECT powersync_replace_schema(?)", parameters: [.string(asString)])

            for reader in readers {
                // Update the schema on all read connections
                let _ = try reader.execute(sql: "pragma table_info('sqlite_master')", parameters: [])
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
        await group.syncCoordinator.disconnect()
    }
    
    func syncStream(name: String, params: JsonParam?) -> any SyncStream {
        PendingSyncStream(db: self, name: name, parameters: params)
    }
    
    func close() async throws {
        try await initialize()
        try await initializer.close {
            await group.syncCoordinator.disconnect()
            try await pool.close()
        }
    }
    
    func close(deleteDatabase: Bool) async throws {
        try await close()
        if deleteDatabase, let dbFilename {
            // We can use the supplied dbLocation when we support that in future
            let directory = try DatabaseLocation.appleDefaultDatabaseDirectory()
            try deleteSQLiteFiles(dbFilename: dbFilename, in: directory)
        }
    }

    func connect(connector: any PowerSyncBackendConnectorProtocol, options: ConnectOptions?) async throws {
        try await initialize()
        await group.syncCoordinator.connect(db: self, connector: connector, options: options ?? ConnectOptions(), client: httpClient)
    }

    func disconnectAndClear(clearLocal: Bool, soft: Bool) async throws {
        try await initialize()
        try await group.syncCoordinator.disconnectAndThen {
            var flags = 0
            if clearLocal {
                flags |= 1
            }
            if soft {
                flags |= 2
            }
            
            do {
                let flags = flags
                let _ = try await writeLockInner { ctx in try ctx.execute(sql: "SELECT powersync_clear(?)", parameters: [flags]) }
            }
        }
    }

    func writeLock<R: Sendable>(callback: @escaping @Sendable (any ConnectionContext) throws -> R) async throws -> R {
        try await initialize()
        return try await writeLockInner(callback: callback)
    }

    fileprivate func writeLockInner<R: Sendable>(callback: @escaping @Sendable (any ConnectionContext) throws -> R) async throws -> R {
        return try await self.pool.write { connection in
            try callback(ConnectionLeaseContext(lease: connection))
        }
    }

    func readLock<R: Sendable>(callback: @escaping @Sendable (any ConnectionContext) throws -> R) async throws -> R {
        try await initialize()
        return try await readLockInner(callback: callback)
    }

    fileprivate func readLockInner<R: Sendable>(callback: @escaping @Sendable (any ConnectionContext) throws -> R) async throws -> R {
        return try await pool.read { connection in
            try callback(ConnectionLeaseContext(lease: connection))
        }
    }

    func watch<RowType: Sendable>(options: WatchOptions<RowType>) throws -> AsyncThrowingStream<[RowType], any Error> {
        return watchImpl(db: self, options: options)
    }

    func requestCheckpoint() async throws -> any CheckpointRequest {
        try await initialize()

        try await group.syncCoordinator.guardNotConnected(
            inner: {
                throw CheckPointRequestError.notConnected
            },
            ifConnected: {
             }
        )

        // perform the request given the instance and auth

        // return a CheckpointRequestImpl
        final class Test: CheckpointRequest {
            func waitForSync() async throws {
                
            }

            
        }

        return Test()
    }

    static let maxOpId = Int64.max
}

private actor DatabaseInitializationAction {
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

        powerSyncVersion = try await db.writeLockInner { conn in
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

func deleteSQLiteFiles(dbFilename: String, in directory: URL) throws {
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
