import Foundation
import PowerSyncKotlin

final class KotlinPowerSyncDatabaseImpl: PowerSyncDatabaseProtocol {
    let logger: any LoggerProtocol

    private let kotlinDatabase: PowerSyncKotlin.PowerSyncDatabase
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
        self.currentStatus = KotlinSyncStatus(
            baseStatus: kotlinDatabase.currentStatus
        )
    }

    func waitForFirstSync() async throws {
        try await kotlinDatabase.waitForFirstSync()
    }

    func updateSchema(schema: any SchemaProtocol) async throws {
        try await kotlinDatabase.updateSchema(schema: KotlinAdapter.Schema.toKotlin(schema))
    }

    func waitForFirstSync(priority: Int32) async throws {
        try await kotlinDatabase.waitForFirstSync(priority: priority)
    }

    func connect(
        connector: PowerSyncBackendConnector,
        crudThrottleMs: Int64 = 1000,
        retryDelayMs: Int64 = 5000,
        params: [String: JsonParam?] = [:]
    ) async throws {
        let connectorAdapter = PowerSyncBackendConnectorAdapter(
            swiftBackendConnector: connector,
            db: self
        )

        try await kotlinDatabase.connect(
            connector: connectorAdapter,
            crudThrottleMs: crudThrottleMs,
            retryDelayMs: retryDelayMs,
            params: params
        )
    }

    func getCrudBatch(limit: Int32 = 100) async throws -> CrudBatch? {
        guard let base = try await kotlinDatabase.getCrudBatch(limit: limit) else {
            return nil
        }
       return try KotlinCrudBatch(base)
    }

    func getNextCrudTransaction() async throws -> CrudTransaction? {
        guard let base = try await kotlinDatabase.getNextCrudTransaction() else {
            return nil
        }
       return try KotlinCrudTransaction(base)
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

    func execute(sql: String, parameters: [Any?]?) async throws -> Int64 {
        try await writeTransaction {ctx in
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
        try await readTransaction { ctx in
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
        try await readTransaction { ctx in
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
        try await readTransaction { ctx in
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
        try await readTransaction { ctx in
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
        try await readTransaction { ctx in
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
        try await readTransaction { ctx in
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
                    var mapperError: Error?
                    // HACK!
                    // SKIEE doesn't support custom exceptions in Flows
                    // Exceptions which occur in the Flow itself cause runtime crashes.
                    // The most probable crash would be the internal EXPLAIN statement.
                    // This attempts to EXPLAIN the query before passing it to Kotlin
                    // We could introduce an onChange API in Kotlin which we use to implement watches here.
                    // This would prevent most issues with exceptions.
                    // EXPLAIN statement to prevent crashes in SKIEE
                    _ = try await self.kotlinDatabase.getAll(
                        sql: "EXPLAIN \(options.sql)",
                        parameters: mapParameters(options.parameters),
                        mapper: { _ in "" }
                    )

                    // Watching for changes in the database
                    for try await values in try self.kotlinDatabase.watch(
                        sql: options.sql,
                        parameters: mapParameters(options.parameters),
                        throttleMs: KotlinLong(value: options.throttleMs),
                        mapper: { cursor in
                            do {
                                return try options.mapper(KotlinSqlCursor(base: cursor))
                            } catch {
                                mapperError = error
                                return ()
                            }
                        }
                    ) {
                        // Check if the outer task is cancelled
                        try Task.checkCancellation() // This checks if the calling task was cancelled

                        if mapperError != nil {
                            throw mapperError!
                        }

                        try continuation.yield(safeCast(values, to: [RowType].self))
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

    func writeTransaction<R>(callback: @escaping (any ConnectionContext) throws -> R) async throws -> R {
        return try safeCast(
            await kotlinDatabase.writeTransaction(
                callback: TransactionCallback(
                    callback: callback
                )
            ),
            to: R.self
        )
    }

    func readTransaction<R>(callback: @escaping (any ConnectionContext) throws -> R) async throws -> R {
        return try safeCast(
            await kotlinDatabase.readTransaction(
                callback: TransactionCallback(
                    callback: callback
                )
            ),
            to: R.self
        )
    }

    func close() async throws {
        try await kotlinDatabase.close()
    }
}
