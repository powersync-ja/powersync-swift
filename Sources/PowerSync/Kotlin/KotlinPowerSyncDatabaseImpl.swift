import Foundation
import PowerSyncKotlin

final class KotlinPowerSyncDatabaseImpl: PowerSyncDatabaseProtocol {
    private let kotlinDatabase: PowerSyncKotlin.PowerSyncDatabase

    var currentStatus: SyncStatus { kotlinDatabase.currentStatus }

    init(
        schema: Schema,
        dbFilename: String
    ) {
        let factory = PowerSyncKotlin.DatabaseDriverFactory()
        kotlinDatabase = PowerSyncDatabase(
            factory: factory,
            schema: KotlinAdapter.Schema.toKotlin(schema),
            dbFilename: dbFilename
        )
    }

    init(kotlinDatabase: KotlinPowerSyncDatabase) {
        self.kotlinDatabase = kotlinDatabase
    }

    func waitForFirstSync() async throws {
        try await kotlinDatabase.waitForFirstSync()
    }

    func connect(
        connector: PowerSyncBackendConnector,
        crudThrottleMs: Int64 = 1000,
        retryDelayMs: Int64 = 5000,
        params: [String: JsonParam?] = [:]
    ) async throws {
        let connectorAdapter = PowerSyncBackendConnectorAdapter(swiftBackendConnector: connector)

        try await kotlinDatabase.connect(
            connector: connectorAdapter,
            crudThrottleMs: crudThrottleMs,
            retryDelayMs: retryDelayMs,
            params: params
        )
    }

    func getCrudBatch(limit: Int32 = 100) async throws -> CrudBatch? {
        try await kotlinDatabase.getCrudBatch(limit: limit)
    }

    func getNextCrudTransaction() async throws -> CrudTransaction? {
        try await kotlinDatabase.getNextCrudTransaction()
    }

    func getPowerSyncVersion() async throws -> String {
        try await kotlinDatabase.getPowerSyncVersion()
    }

    func disconnect() async throws {
        try await kotlinDatabase.disconnect()
    }

    func disconnectAndClear(clearLocal: Bool = true) async throws {
        try await kotlinDatabase.disconnectAndClear(clearLocal: clearLocal)
    }

    func execute(sql: String, parameters: [Any]?) async throws -> Int64 {
        try Int64(truncating: await kotlinDatabase.execute(sql: sql, parameters: parameters))
    }

    func get<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType {
        try safeCast(await kotlinDatabase.get(
            sql: sql,
            parameters: parameters,
            mapper: mapper
        ), to: RowType.self)
    }

    func get<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType {
        return try await wrapQueryCursorTyped(
            mapper: mapper,
            executor: { wrappedMapper in
                try await self.kotlinDatabase.get(
                    sql: sql,
                    parameters: parameters,
                    mapper: wrappedMapper
                )
            },
            resultType: RowType.self
        )
    }

    func getAll<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> [RowType] {
        try safeCast(await kotlinDatabase.getAll(
            sql: sql,
            parameters: parameters,
            mapper: mapper
        ), to: [RowType].self)
    }

    func getAll<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> [RowType] {
        try await wrapQueryCursorTyped(
            mapper: mapper,
            executor: { wrappedMapper in
                try await self.kotlinDatabase.getAll(
                    sql: sql,
                    parameters: parameters,
                    mapper: wrappedMapper
                )
            },
            resultType: [RowType].self
        )
    }

    func getOptional<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType? {
        try safeCast(await kotlinDatabase.getOptional(
            sql: sql,
            parameters: parameters,
            mapper: mapper
        ), to: RowType?.self)
    }

    func getOptional<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType? {
        try await wrapQueryCursorTyped(
            mapper: mapper,
            executor: { wrappedMapper in
                try await self.kotlinDatabase.getOptional(
                    sql: sql,
                    parameters: parameters,
                    mapper: wrappedMapper
                )
            },
            resultType: RowType?.self
        )
    }

    func watch<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) throws -> AsyncThrowingStream<[RowType], Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for await values in try self.kotlinDatabase.watch(
                        sql: sql,
                        parameters: parameters,
                        mapper: mapper
                    ) {
                        try continuation.yield(safeCast(values, to: [RowType].self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func watch<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) throws -> AsyncThrowingStream<[RowType], Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var mapperError: Error?
                    for try await values in try self.kotlinDatabase.watch(
                        sql: sql,
                        parameters: parameters,
                        mapper: { cursor in do {
                            return try mapper(cursor)
                        } catch {
                            mapperError = error
                            // The value here does not matter. We will throw the exception later
                            // This is not ideal, this is only a workaround until we expose fine grained access to Kotlin SDK internals.
                            return nil as RowType?
                        } }
                    ) {
                        if mapperError != nil {
                            throw mapperError!
                        }
                        try continuation.yield(safeCast(values, to: [RowType].self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func writeTransaction<R>(callback: @escaping (any PowerSyncTransaction) throws -> R) async throws -> R {
        return try safeCast(await kotlinDatabase.writeTransaction(callback: TransactionCallback(callback: callback)), to: R.self)
    }

    public func readTransaction<R>(callback: @escaping (any PowerSyncTransaction) throws -> R) async throws -> R {
        return try safeCast(await kotlinDatabase.readTransaction(callback: TransactionCallback(callback: callback)), to: R.self)
    }
}

