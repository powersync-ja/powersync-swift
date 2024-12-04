import Foundation
import PowerSync

final class KotlinPowerSyncDatabaseImpl: PowerSyncDatabaseProtocol {
    private let kotlinDatabase: PowerSync.PowerSyncDatabase

    var currentStatus: SyncStatus {
        get { kotlinDatabase.currentStatus }
    }

    init(
        schema: Schema,
        dbFilename: String
    ) {
        let factory = PowerSync.DatabaseDriverFactory()
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

    func watch<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) -> AsyncStream<[RowType]> {
        AsyncStream { continuation in
            Task {
                for await values in self.kotlinDatabase.watch(
                    sql: sql,
                    parameters: parameters,
                    mapper: mapper
                ) {
                    continuation.yield(values as! [RowType])
                }
                continuation.finish()
            }
        }
    }

    public func writeTransaction<R>(callback: @escaping (any PowerSyncTransaction) async throws -> R) async throws -> R {
        return try await kotlinDatabase.writeTransaction(callback: SuspendTaskWrapper { transaction in
            return try await callback(transaction)
        }) as! R
    }

    public func readTransaction<R>(callback: @escaping (any PowerSyncTransaction) async throws -> R) async throws -> R {
        return try await kotlinDatabase.writeTransaction(callback: SuspendTaskWrapper { transaction in
            return try await callback(transaction)
        }) as! R
    }
}

enum PowerSyncError: Error {
    case invalidTransaction
}

class SuspendTaskWrapper: KotlinSuspendFunction1 {
    let handle: (any PowerSyncTransaction) async throws -> Any

    init(_ handle: @escaping (any PowerSyncTransaction) async throws -> Any) {
        self.handle = handle
    }

    func __invoke(p1: Any?, completionHandler: @escaping (Any?, Error?) -> Void) {
        Task {
            do {
                let result = try await self.handle(p1 as! any PowerSyncTransaction)
                completionHandler(result, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }
}
