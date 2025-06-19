import Foundation

/// Options for configuring a PowerSync connection.
///
/// Provides optional parameters to customize sync behavior such as throttling and retry policies.
public struct ConnectOptions {
    /// Defaults to 1 second
    public static let DefaultCrudThrottle: TimeInterval = 1
    
    /// Defaults to 5 seconds
    public static let DefaultRetryDelay: TimeInterval = 5
    
    /// TimeInterval (in seconds) between CRUD (Create, Read, Update, Delete) operations.
    ///
    /// Default is ``ConnectOptions/DefaultCrudThrottle``.
    /// Increase this value to reduce load on the backend server.
    public var crudThrottle: TimeInterval

    /// Delay TimeInterval (in seconds) before retrying after a connection failure.
    ///
    /// Default is ``ConnectOptions/DefaultRetryDelay``.
    /// Increase this value to wait longer before retrying connections in case of persistent failures.
    public var retryDelay: TimeInterval

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
    
    /// Uses a new sync client implemented in Rust instead of the one implemented in Kotlin.
    ///
    /// The new client is more efficient and will become the default in the future, but is still marked as experimental for now.
    /// We encourage interested users to try the new client.
    @_spi(PowerSyncExperimental)
    public var newClientImplementation: Bool

    /// The connection method used to connect to the Powersync service.
    ///
    /// The default method is ``ConnectionMethod/http``. Using ``ConnectionMethod/webSocket(_:)`` can
    /// improve performance as a more efficient binary protocol is used. However, using the websocket connection method
    /// requires enabling ``ConnectOptions/newClientImplementation``.
    @_spi(PowerSyncExperimental)
    public var connectionMethod: ConnectionMethod
    
    /// Initializes a `ConnectOptions` instance with optional values.
    ///
    /// - Parameters:
    ///   - crudThrottle: TimeInterval between CRUD operations in milliseconds. Defaults to `1` second.
    ///   - retryDelay: Delay TimeInterval between retry attempts in milliseconds. Defaults to `5` seconds.
    ///   - params: Custom sync parameters to send to the server. Defaults to an empty dictionary.
    public init(
        crudThrottle: TimeInterval = 1,
        retryDelay: TimeInterval = 5,
        params: JsonParam = [:]
    ) {
        self.crudThrottle = crudThrottle
        self.retryDelay = retryDelay
        self.params = params
        self.newClientImplementation = false
        self.connectionMethod = .http
    }
    
    /// Initializes a ``ConnectOptions`` instance with optional values, including experimental options.
    @_spi(PowerSyncExperimental)
    public init(
        crudThrottle: TimeInterval = 1,
        retryDelay: TimeInterval = 5,
        params: JsonParam = [:],
        newClientImplementation: Bool = false,
        connectionMethod: ConnectionMethod = .http,
    ) {
        self.crudThrottle = crudThrottle
        self.retryDelay = retryDelay
        self.params = params
        self.newClientImplementation = newClientImplementation
        self.connectionMethod = connectionMethod
    }
}

@_spi(PowerSyncExperimental)
public enum ConnectionMethod {
    case http
    case webSocket
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
    ///   - crudThrottle: TimeInterval between CRUD operations. Defaults to ``ConnectOptions/DefaultCrudThrottle``.
    ///   - retryDelay: Delay TimeInterval between retries after failure. Defaults to ``ConnectOptions/DefaultRetryDelay``.
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
        crudThrottle: TimeInterval = 1,
        retryDelay: TimeInterval = 5,
        params: JsonParam = [:]
    ) async throws {
        try await connect(
            connector: connector,
            options: ConnectOptions(
                crudThrottle: crudThrottle,
                retryDelay: retryDelay,
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
