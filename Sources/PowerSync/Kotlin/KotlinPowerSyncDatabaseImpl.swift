import Foundation
import PowerSyncKotlin

final class KotlinPowerSyncDatabaseImpl: PowerSyncDatabaseProtocol,
    // `PowerSyncKotlin.PowerSyncDatabase` cannot be marked as Sendable
    @unchecked Sendable
{
    let logger: any LoggerProtocol
    private let kotlinDatabase: PowerSyncKotlin.PowerSyncDatabase
    private let encoder = JSONEncoder()
    let currentStatus: SyncStatus
    private let dbFilename: String

    init(
        schema: Schema,
        dbFilename: String,
        logger: DatabaseLogger
    ) {
        let factory = PowerSyncKotlin.DatabaseDriverFactory()
        kotlinDatabase = PowerSyncDatabase(
            factory: factory,
            schema: KotlinAdapter.Schema.toKotlin(schema),
            dbFilename: dbFilename,
            logger: logger.kLogger
        )
        self.logger = logger
        self.dbFilename = dbFilename
        currentStatus = KotlinSyncStatus(
            baseStatus: kotlinDatabase.currentStatus
        )
    }

    func waitForFirstSync() async throws {
        try await kotlinDatabase.waitForFirstSync()
    }

    func updateSchema(schema: any SchemaProtocol) async throws {
        try await kotlinDatabase.updateSchema(
            schema: KotlinAdapter.Schema.toKotlin(schema)
        )
    }

    func waitForFirstSync(priority: Int32) async throws {
        try await kotlinDatabase.waitForFirstSync(
            priority: priority
        )
    }

    func connect(
        connector: PowerSyncBackendConnectorProtocol,
        options: ConnectOptions?
    ) async throws {
        let connectorAdapter = swiftBackendConnectorToPowerSyncConnector(connector: SwiftBackendConnectorBridge(
            swiftBackendConnector: connector, db: self
        ))

        let resolvedOptions = options ?? ConnectOptions()
        try await kotlinDatabase.connect(
            connector: connectorAdapter,
            crudThrottleMs: Int64(resolvedOptions.crudThrottle * 1000),
            retryDelayMs: Int64(resolvedOptions.retryDelay * 1000),
            params: resolvedOptions.params.mapValues { $0.toKotlinMap() },
            options: createSyncOptions(
                newClient: resolvedOptions.newClientImplementation,
                userAgent: userAgent(),
                loggingConfig: resolvedOptions.clientConfiguration?.requestLogger?.toKotlinConfig()
            )
        )
    }

    func getCrudBatch(limit: Int32 = 100) async throws -> CrudBatch? {
        guard let base = try await kotlinDatabase.getCrudBatch(limit: limit) else {
            return nil
        }
        return try KotlinCrudBatch(
            batch: base
        )
    }

    func getCrudTransactions() -> any CrudTransactions {
        return KotlinCrudTransactions(db: kotlinDatabase)
    }

    func getPowerSyncVersion() async throws -> String {
        try await kotlinDatabase.getPowerSyncVersion()
    }

    func disconnect() async throws {
        try await kotlinDatabase.disconnect()
    }

    func disconnectAndClear(clearLocal: Bool = true) async throws {
        try await kotlinDatabase.disconnectAndClear(
            clearLocal: clearLocal
        )
    }

    @discardableResult
    func execute(sql: String, parameters: [Sendable?]?) async throws -> Int64 {
        try await writeTransaction { ctx in
            try ctx.execute(
                sql: sql,
                parameters: parameters
            )
        }
    }

    func get<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) -> RowType
    ) async throws -> RowType {
        try await readLock { ctx in
            try ctx.get(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func get<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType {
        try await readLock { ctx in
            try ctx.get(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func getAll<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) -> RowType
    ) async throws -> [RowType] {
        try await readLock { ctx in
            try ctx.getAll(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func getAll<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) async throws -> [RowType] {
        try await readLock { ctx in
            try ctx.getAll(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func getOptional<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) -> RowType
    ) async throws -> RowType? {
        try await readLock { ctx in
            try ctx.getOptional(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func getOptional<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType? {
        try await readLock { ctx in
            try ctx.getOptional(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func watch<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) -> RowType
    ) throws -> AsyncThrowingStream<[RowType], any Error> {
        try watch(
            options: WatchOptions(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        )
    }

    func watch<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) throws -> AsyncThrowingStream<[RowType], any Error> {
        try watch(
            options: WatchOptions(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        )
    }

    func watch<RowType: Sendable>(
        options: WatchOptions<RowType>
    ) throws -> AsyncThrowingStream<[RowType], Error> {
        AsyncThrowingStream { continuation in
            // Create an outer task to monitor cancellation
            let task = Task {
                do {
                    let watchedTables = try await self.getQuerySourceTables(
                        sql: options.sql,
                        parameters: options.parameters
                    )

                    // Watching for changes in the database
                    for try await _ in try self.kotlinDatabase.onChange(
                        tables: Set(watchedTables),
                        throttleMs: Int64(options.throttle * 1000),
                        triggerImmediately: true // Allows emitting the first result even if there aren't changes
                    ) {
                        // Check if the outer task is cancelled
                        try Task.checkCancellation()

                        try continuation.yield(
                            safeCast(
                                await self.getAll(
                                    sql: options.sql,
                                    parameters: options.parameters,
                                    mapper: options.mapper
                                ),
                                to: [RowType].self
                            )
                        )
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

    func writeLock<R: Sendable>(
        callback: @Sendable @escaping (any ConnectionContext) throws -> R
    ) async throws -> R {
        return try await wrapPowerSyncException {
            try safeCast(
                await kotlinDatabase.writeLock(
                    callback: wrapLockContext(callback: callback)
                ),
                to: R.self
            )
        }
    }

    func writeTransaction<R: Sendable>(
        callback: @Sendable @escaping (any Transaction) throws -> R
    ) async throws -> R {
        return try await wrapPowerSyncException {
            try safeCast(
                await kotlinDatabase.writeTransaction(
                    callback: wrapTransactionContext(callback: callback)
                ),
                to: R.self
            )
        }
    }

    func readLock<R: Sendable>(
        callback: @Sendable @escaping (any ConnectionContext) throws -> R
    )
        async throws -> R
    {
        return try await wrapPowerSyncException {
            try safeCast(
                await kotlinDatabase.readLock(
                    callback: wrapLockContext(callback: callback)
                ),
                to: R.self
            )
        }
    }

    func readTransaction<R: Sendable>(
        callback: @Sendable @escaping (any Transaction) throws -> R
    ) async throws -> R {
        return try await wrapPowerSyncException {
            try safeCast(
                await kotlinDatabase.readTransaction(
                    callback: wrapTransactionContext(callback: callback)
                ),
                to: R.self
            )
        }
    }

    func close() async throws {
        try await kotlinDatabase.close()
    }

    func close(deleteDatabase: Bool = false) async throws {
        // Close the SQLite connections
        try await close()

        if deleteDatabase {
            try await self.deleteDatabase()
        }
    }

    private func deleteDatabase() async throws {
        // We can use the supplied dbLocation when we support that in future
        let directory = try appleDefaultDatabaseDirectory()
        try deleteSQLiteFiles(dbFilename: dbFilename, in: directory)
    }

    /// Tries to convert Kotlin PowerSyncExceptions to Swift Exceptions
    private func wrapPowerSyncException<R: Sendable>(
        handler: () async throws -> R)
        async throws -> R
    {
        do {
            return try await handler()
        } catch {
            // Try and parse errors back from the Kotlin side
            if let mapperError = SqlCursorError.fromDescription(error.localizedDescription) {
                throw mapperError
            }

            throw PowerSyncError.operationFailed(
                underlyingError: error
            )
        }
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
            let pagesData = try encoder.encode(rootPages)

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
}

private struct ExplainQueryResult {
    let addr: String
    let opcode: String
    let p1: Int64
    let p2: Int64
    let p3: Int64
}

extension Error {
    func toPowerSyncError() -> PowerSyncKotlin.PowerSyncException {
        return PowerSyncKotlin.PowerSyncException(
            message: localizedDescription,
            cause: PowerSyncKotlin.KotlinThrowable(message: localizedDescription)
        )
    }
}

func wrapLockContext(
    callback: @Sendable @escaping (any ConnectionContext) throws -> Any
) throws -> PowerSyncKotlin.ThrowableLockCallback {
    PowerSyncKotlin.wrapContextHandler { kotlinContext in
        do {
            return try PowerSyncKotlin.PowerSyncResult.Success(
                value: callback(
                    KotlinConnectionContext(
                        ctx: kotlinContext
                    )
                ))
        } catch {
            return PowerSyncKotlin.PowerSyncResult.Failure(
                exception: error.toPowerSyncError()
            )
        }
    }
}

func wrapTransactionContext(
    callback: @Sendable @escaping (any Transaction) throws -> Any
) throws -> PowerSyncKotlin.ThrowableTransactionCallback {
    PowerSyncKotlin.wrapTransactionContextHandler { kotlinContext in
        do {
            return try PowerSyncKotlin.PowerSyncResult.Success(
                value: callback(
                    KotlinTransactionContext(
                        ctx: kotlinContext
                    )
                ))
        } catch {
            return PowerSyncKotlin.PowerSyncResult.Failure(
                exception: error.toPowerSyncError()
            )
        }
    }
}

/// This returns the default directory in which we store SQLite database files.
func appleDefaultDatabaseDirectory() throws -> URL {
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

/// Deletes all SQLite files for a given database filename in the specified directory.
/// This includes the main database file and WAL mode files (.wal, .shm, and .journal if present).
/// Throws an error if a file exists but could not be deleted. Files that don't exist are ignored.
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
        let fileURL = directory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        // If file doesn't exist, we ignore it and continue
    }
}
