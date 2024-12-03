import Foundation
import PowerSync

final class KotlinPowerSyncDatabaseImpl: PowerSyncDatabaseProtocol {
    private let kmpDatabase: PowerSync.PowerSyncDatabase
    
    var currentStatus: SyncStatus {
        get { kmpDatabase.currentStatus }
    }
    
    init(
        schema: Schema,
        dbFilename: String
    ) {
        let factory = PowerSync.DatabaseDriverFactory()
        self.kmpDatabase = PowerSyncDatabase(
            factory: factory,
            schema: KotlinAdapter.Schema.toKotlin(schema),
            dbFilename: dbFilename
        )
    }

    func waitForFirstSync() async throws {
        try await kmpDatabase.waitForFirstSync()
    }
    
    func connect(
        connector: PowerSyncBackendConnector,
        crudThrottleMs: Int64 = 1000,
        retryDelayMs: Int64 = 5000,
        params: [String: JsonParam?] = [:]
    ) async throws {
        try await kmpDatabase.connect(
            connector: connector,
            crudThrottleMs: crudThrottleMs,
            retryDelayMs: retryDelayMs,
            params: params
        )
    }
    
    func getCrudBatch(limit: Int32 = 100) async throws -> CrudBatch? {
        try await kmpDatabase.getCrudBatch(limit: limit)
    }
    
    func getNextCrudTransaction() async throws -> CrudTransaction? {
        try await kmpDatabase.getNextCrudTransaction()
    }
    
    func getPowerSyncVersion() async throws -> String {
        try await kmpDatabase.getPowerSyncVersion()
    }
    
    func disconnect() async throws {
        try await kmpDatabase.disconnect()
    }
    
    func disconnectAndClear(clearLocal: Bool = true) async throws {
        try await kmpDatabase.disconnectAndClear(clearLocal: clearLocal)
    }
    
    func execute(sql: String, parameters: [Any]?) async throws -> Int64 {
        Int64(truncating: try await kmpDatabase.execute(sql: sql, parameters: parameters))
    }
    
    func get<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType {
        try await kmpDatabase.get(
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
        try await kmpDatabase.getAll(
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
        try await kmpDatabase.getOptional(
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
                for await values in self.kmpDatabase.watch(
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
    
    @MainActor
    public func writeTransaction<R>(callback: @escaping (any PowerSyncTransaction) async throws -> R) async throws -> R {
        return try await kmpDatabase.writeTransaction(callback: SuspendTaskWrapper { transaction in
            return try await callback(transaction)
        }) as! R
    }
    
    @MainActor
    public func readTransaction<R>(callback: @escaping (any PowerSyncTransaction) async throws -> R) async throws -> R {
        return try await kmpDatabase.writeTransaction(callback: SuspendTaskWrapper { transaction in
            return try await callback(transaction)
        }) as! R
    }
}

enum PowerSyncError: Error {
    case invalidTransaction
}

@MainActor
class SuspendTaskWrapper: KotlinSuspendFunction1 {
    let handle: (any PowerSyncTransaction) async throws -> Any

    init(_ handle: @escaping (any PowerSyncTransaction) async throws -> Any) {
        self.handle = handle
    }

    nonisolated func __invoke(p1: Any?, completionHandler: @escaping (Any?, Error?) -> Void) {
        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    let result = try await self.handle(p1 as! any PowerSyncTransaction)
                    completionHandler(result, nil)
                } catch {
                    completionHandler(nil, error)
                }
            }
        }
    }
}
