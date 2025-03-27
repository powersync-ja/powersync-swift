import Foundation

/// A PowerSync managed database.
///
/// Use one instance per database file.
///
/// Use `PowerSyncDatabase.connect` to connect to the PowerSync service, to keep the local database in sync with the remote database.
///
/// All changes to local tables are automatically recorded, whether connected or not. Once connected, the changes are uploaded.
public protocol PowerSyncDatabaseProtocol: Queries {
    /// The current sync status.
    var currentStatus: SyncStatus { get }
    
    /// Wait for the first sync to occur
    func waitForFirstSync() async throws
    

    /// Replace the schema with a new version. This is for advanced use cases - typically the schema
    /// should just be specified once in the constructor.
    ///
    /// Cannot be used while connected - this should only be called before connect.
    func updateSchema(schema: SchemaProtocol) async throws
   
    /// Wait for the first (possibly partial) sync to occur that contains all buckets in the given priority.
    func waitForFirstSync(priority: Int32) async throws
    
    /// Connect to the PowerSync service, and keep the databases in sync.
    ///
    /// The connection is automatically re-opened if it fails for any reason.
    ///
    /// - Parameters:
    ///   - connector: The PowerSyncBackendConnector to use
    ///   - crudThrottleMs: Time between CRUD operations. Defaults to 1000ms.
    ///   - retryDelayMs: Delay between retries after failure. Defaults to 5000ms.
    ///   - params: Sync parameters from the client
    ///
    /// Example usage:
    /// ```swift
    /// let params: [String: JsonParam] = [
    ///     "name": .string("John Doe"),
    ///     "age": .number(30),
    ///     "isStudent": .boolean(false)
    /// ]
    ///
    /// try await connect(
    ///     connector: connector,
    ///     crudThrottleMs: 2000,
    ///     retryDelayMs: 10000,
    ///     params: params
    /// )
    /// ```
    func connect(
        connector: PowerSyncBackendConnector,
        crudThrottleMs: Int64,
        retryDelayMs: Int64,
        params: [String: JsonParam?]
    ) async throws
    
    /// Get a batch of crud data to upload.
    ///
    /// Returns nil if there is no data to upload.
    ///
    /// Use this from the `PowerSyncBackendConnector.uploadData` callback.
    ///
    /// Once the data have been successfully uploaded, call `CrudBatch.complete` before
    /// requesting the next batch.
    ///
    /// - Parameter limit: Maximum number of updates to return in a single batch. Default is 100.
    ///
    /// This method does include transaction ids in the result, but does not group
    /// data by transaction. One batch may contain data from multiple transactions,
    /// and a single transaction may be split over multiple batches.
    func getCrudBatch(limit: Int32) async throws -> CrudBatch?
    
    /// Get the next recorded transaction to upload.
    ///
    /// Returns nil if there is no data to upload.
    ///
    /// Use this from the `PowerSyncBackendConnector.uploadData` callback.
    ///
    /// Once the data have been successfully uploaded, call `CrudTransaction.complete` before
    /// requesting the next transaction.
    ///
    /// Unlike `getCrudBatch`, this only returns data from a single transaction at a time.
    /// All data for the transaction is loaded into memory.
    func getNextCrudTransaction() async throws -> CrudTransaction?
    
    /// Convenience method to get the current version of PowerSync.
    func getPowerSyncVersion() async throws -> String
    
    /// Close the sync connection.
    ///
    /// Use `connect` to connect again.
    func disconnect() async throws
    
    /// Disconnect and clear the database.
    /// Use this when logging out.
    /// The database can still be queried after this is called, but the tables
    /// would be empty.
    ///
    /// - Parameter clearLocal: Set to false to preserve data in local-only tables.
    func disconnectAndClear(clearLocal: Bool) async throws
}

public extension PowerSyncDatabaseProtocol {
    func connect(
        connector: PowerSyncBackendConnector,
        crudThrottleMs: Int64 = 1000,
        retryDelayMs: Int64 = 5000,
        params: [String: JsonParam?] = [:]
    ) async throws {
        try await connect(
            connector: connector,
            crudThrottleMs: crudThrottleMs,
            retryDelayMs: retryDelayMs,
            params: params
        )
    }
    
    func disconnectAndClear(clearLocal: Bool = true) async throws {
        try await disconnectAndClear(clearLocal: clearLocal)
    }
    
    func getCrudBatch(limit: Int32 = 100) async throws -> CrudBatch? {
        try await getCrudBatch(limit: 100)
    }
}
