import Foundation
import PowerSyncKotlin

final class KotlinPowerSyncDatabaseImpl: PowerSyncDatabaseProtocol {
    private let kotlinDatabase: PowerSyncKotlin.PowerSyncDatabase

    var currentStatus: SyncStatus {
        get { kotlinDatabase.currentStatus }
    }

    init(
        schema: Schema,
        dbFilename: String
    ) {
        let factory = PowerSyncKotlin.DatabaseDriverFactory()
        self.kotlinDatabase = PowerSyncDatabase(
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
        Int64(truncating: try await kotlinDatabase.execute(sql: sql, parameters: parameters))
    }

    func get<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType {
        try await kotlinDatabase.get(
            sql: sql,
            parameters: parameters,
            mapper: mapper
        ) as! RowType
    }

    func get<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType {
        try await kotlinDatabase.get(
            sql: sql,
            parameters: parameters,
            mapper: { cursor in
                try! mapper(cursor)
            }
        ) as! RowType
    }

    func getAll<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> [RowType] {
        try await kotlinDatabase.getAll(
            sql: sql,
            parameters: parameters,
            mapper: mapper
        ) as! [RowType]
    }

    func getAll<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> [RowType] {
        try await kotlinDatabase.getAll(
            sql: sql,
            parameters: parameters,
            mapper: { cursor in
                try! mapper(cursor)
            }
        ) as! [RowType]
    }

    func getOptional<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType? {
        try await kotlinDatabase.getOptional(
            sql: sql,
            parameters: parameters,
            mapper: mapper
        ) as! RowType?
    }

    func getOptional<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType? {
        try await kotlinDatabase.getOptional(
            sql: sql,
            parameters: parameters,
            mapper: { cursor in
                try! mapper(cursor)
            }
        ) as! RowType?
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
                        continuation.yield(values as! [RowType])
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
                    for await values in try self.kotlinDatabase.watch(
                        sql: sql,
                        parameters: parameters,
                        mapper: { cursor in
                            try! mapper(cursor)
                        }
                    ) {
                        continuation.yield(values as! [RowType])
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func writeTransaction<R>(callback: @escaping (any PowerSyncTransaction) -> R) async throws -> R {
        return try await kotlinDatabase.writeTransaction(callback: callback) as! R
    }

    public func readTransaction<R>(callback: @escaping (any PowerSyncTransaction) -> R) async throws -> R {
        return try await kotlinDatabase.readTransaction(callback: callback) as! R
    }
}

enum PowerSyncError: Error {
    case invalidTransaction
}
