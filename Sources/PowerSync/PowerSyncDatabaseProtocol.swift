import Foundation

/// Options for configuring a PowerSync connection.
///
/// Provides optional parameters to customize sync behavior such as throttling and retry policies.
public struct ConnectOptions {
    /// Time in milliseconds between CRUD (Create, Read, Update, Delete) operations.
    ///
    /// Default is `1000` ms (1 second).
    /// Increase this value to reduce load on the backend server.
    public var crudThrottleMs: Int64

    /// Delay in milliseconds before retrying after a connection failure.
    ///
    /// Default is `5000` ms (5 seconds).
    /// Increase this value to wait longer before retrying connections in case of persistent failures.
    public var retryDelayMs: Int64

    /// Additional sync parameters passed to the server during connection.
    ///
    /// This can be used to send custom values such as user identifiers, feature flags, etc.
    ///
    /// Example:
    /// ```swift
    /// [
    ///     "userId": .string("abc123"),
    ///     "debugMode": .boolean(true)
    /// ]
    /// ```
    public var params: JsonParam

    /// Initializes a `ConnectOptions` instance with optional values.
    ///
    /// - Parameters:
    ///   - crudThrottleMs: Time between CRUD operations in milliseconds. Defaults to `1000`.
    ///   - retryDelayMs: Delay between retry attempts in milliseconds. Defaults to `5000`.
    ///   - params: Custom sync parameters to send to the server. Defaults to an empty dictionary.
    public init(
        crudThrottleMs: Int64 = 1000,
        retryDelayMs: Int64 = 5000,
        params: JsonParam = [:]
    ) {
        self.crudThrottleMs = crudThrottleMs
        self.retryDelayMs = retryDelayMs
        self.params = params
    }
}


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
    
    /// Logger used for PowerSync operations
    var logger: any LoggerProtocol { get }
    
    /// Wait for the first sync to occur
    func waitForFirstSync() async throws
    

    /// Replace the schema with a new version. This is for advanced use cases - typically the schema
    /// should just be specified once in the constructor.
    ///
    /// Cannot be used while connected - this should only be called before connect.
    func updateSchema(schema: SchemaProtocol) async throws
   
    /// Wait for the first (possibly partial) sync to occur that contains all buckets in the given priority.
    func waitForFirstSync(priority: Int32) async throws
    
    /// Connects to the PowerSync service and keeps the local database in sync with the remote database.
    ///
    /// The connection is automatically re-opened if it fails for any reason.
    /// You can customize connection behavior using the `ConnectOptions` parameter.
    ///
    /// - Parameters:
    ///   - connector: The `PowerSyncBackendConnector` used to manage the backend connection.
    ///   - options: Optional `ConnectOptions` to customize CRUD throttling, retry delays, and sync parameters.
    ///     If `nil`, default options are used (1000ms CRUD throttle, 5000ms retry delay, empty parameters).
    ///
    /// Example usage:
    /// ```swift
    /// try await database.connect(
    ///     connector: connector,
    ///     options: ConnectOptions(
    ///         crudThrottleMs: 2000,
    ///         retryDelayMs: 10000,
    ///         params: [
    ///             "deviceId": .string("abc123"),
    ///             "platform": .string("iOS")
    ///         ]
    ///     )
    /// )
    /// ```
    ///
    /// You can also omit the `options` parameter to use the default connection behavior:
    /// ```swift
    /// try await database.connect(connector: connector)
    /// ```
    ///
    /// - Throws: An error if the connection fails or if the database is not properly configured.
    func connect(
        connector: PowerSyncBackendConnector,
        options: ConnectOptions?
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
    
    /// Close the database, releasing resources.
    /// Also disconnects any active connection.
    ///
    /// Once close is called, this database cannot be used again - a new one must be constructed.
    func close() async throws
}

public extension PowerSyncDatabaseProtocol {
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
    /// let params: JsonParam = [
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
    func connect(
        connector: PowerSyncBackendConnector,
        crudThrottleMs: Int64 = 1000,
        retryDelayMs: Int64 = 5000,
        params: JsonParam = [:]
    ) async throws {
        try await connect(
            connector: connector,
            options: ConnectOptions(
                crudThrottleMs: crudThrottleMs,
                retryDelayMs: retryDelayMs,
                params: params
            )
        )
    }
    
    func disconnectAndClear(clearLocal: Bool = true) async throws {
        try await self.disconnectAndClear(clearLocal: clearLocal)
    }
    
    func getCrudBatch(limit: Int32 = 100) async throws -> CrudBatch? {
        try await getCrudBatch(
            limit: limit
        )
    }
}
