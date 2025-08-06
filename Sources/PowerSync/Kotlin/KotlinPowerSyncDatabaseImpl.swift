import Foundation
import PowerSyncKotlin

final class KotlinPowerSyncDatabaseImpl: PowerSyncDatabaseProtocol {
    let logger: any LoggerProtocol

    private let kotlinDatabase: PowerSyncKotlin.PowerSyncDatabase
    private let encoder = JSONEncoder()
    let currentStatus: SyncStatus

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
        connector: PowerSyncBackendConnector,
        options: ConnectOptions?
    ) async throws {
        let connectorAdapter = PowerSyncBackendConnectorAdapter(
            swiftBackendConnector: connector,
            db: self
        )

        let resolvedOptions = options ?? ConnectOptions()

        try await kotlinDatabase.connect(
            connector: connectorAdapter,
            crudThrottleMs: Int64(resolvedOptions.crudThrottle * 1000),
            retryDelayMs: Int64(resolvedOptions.retryDelay * 1000),
            params: resolvedOptions.params.mapValues { $0.toKotlinMap() },
            options: createSyncOptions(
                newClient: resolvedOptions.newClientImplementation,
                userAgent: "PowerSync Swift SDK",
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

    func getNextCrudTransaction() async throws -> CrudTransaction? {
        guard let base = try await kotlinDatabase.getNextCrudTransaction() else {
            return nil
        }
        return try KotlinCrudTransaction(
            transaction: base
        )
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
    func execute(sql: String, parameters: [Any?]?) async throws -> Int64 {
        try await writeTransaction { ctx in
            try ctx.execute(
                sql: sql,
                parameters: parameters
            )
        }
    }

    func get<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType {
        try await readLock { ctx in
            try ctx.get(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func get<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType {
        try await readLock { ctx in
            try ctx.get(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func getAll<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> [RowType] {
        try await readLock { ctx in
            try ctx.getAll(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func getAll<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> [RowType] {
        try await readLock { ctx in
            try ctx.getAll(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func getOptional<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType? {
        try await readLock { ctx in
            try ctx.getOptional(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func getOptional<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType? {
        try await readLock { ctx in
            try ctx.getOptional(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        }
    }

    func watch<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) throws -> AsyncThrowingStream<[RowType], any Error> {
        try watch(
            options: WatchOptions(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        )
    }

    func watch<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) throws -> AsyncThrowingStream<[RowType], any Error> {
        try watch(
            options: WatchOptions(
                sql: sql,
                parameters: parameters,
                mapper: mapper
            )
        )
    }

    func watch<RowType>(
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

    func writeLock<R>(
        callback: @escaping (any ConnectionContext) throws -> R
    ) async throws -> R {
        return try await wrapPowerSyncException {
            try safeCast(
                await kotlinDatabase.writeLock(
                    callback: LockCallback(
                        callback: callback
                    )
                ),
                to: R.self
            )
        }
    }

    func writeTransaction<R>(
        callback: @escaping (any Transaction) throws -> R
    ) async throws -> R {
        return try await wrapPowerSyncException {
            try safeCast(
                await kotlinDatabase.writeTransaction(
                    callback: TransactionCallback(
                        callback: callback
                    )
                ),
                to: R.self
            )
        }
    }

    func readLock<R>(
        callback: @escaping (any ConnectionContext) throws -> R
    )
        async throws -> R
    {
        return try await wrapPowerSyncException {
            try safeCast(
                await kotlinDatabase.readLock(
                    callback: LockCallback(
                        callback: callback
                    )
                ),
                to: R.self
            )
        }
    }

    func readTransaction<R>(
        callback: @escaping (any Transaction) throws -> R
    ) async throws -> R {
        return try await wrapPowerSyncException {
            try safeCast(
                await kotlinDatabase.readTransaction(
                    callback: TransactionCallback(
                        callback: callback
                    )
                ),
                to: R.self
            )
        }
    }

    func close() async throws {
        try await kotlinDatabase.close()
    }

    /// Tries to convert Kotlin PowerSyncExceptions to Swift Exceptions
    private func wrapPowerSyncException<R>(
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
        parameters: [Any?]
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

        let rootPages = rows.compactMap { r in
            if (r.opcode == "OpenRead" || r.opcode == "OpenWrite") &&
                r.p3 == 0 && r.p2 != 0
            {
                return r.p2
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
                    pagesString
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
