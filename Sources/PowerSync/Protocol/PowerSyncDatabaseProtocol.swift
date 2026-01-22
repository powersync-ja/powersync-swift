import Foundation

/// Configuration for the sync client used to connect to the PowerSync service.
///
/// Provides options to customize network behavior and logging for PowerSync
/// HTTP requests and responses.
public struct SyncClientConfiguration: Sendable {
    /// Optional configuration for logging PowerSync HTTP requests.
    ///
    /// When provided, network requests will be logged according to the
    /// specified `SyncRequestLoggerConfiguration`. Set to `nil` to disable request logging entirely.
    ///
    /// - SeeAlso: `SyncRequestLoggerConfiguration` for configuration options
    public let requestLogger: SyncRequestLoggerConfiguration?

    /// Creates a new sync client configuration.
    /// - Parameter requestLogger: Optional network logger configuration
    public init(requestLogger: SyncRequestLoggerConfiguration? = nil) {
        self.requestLogger = requestLogger
    }
}

/// Options for configuring a PowerSync connection.
///
/// Provides optional parameters to customize sync behavior such as throttling and retry policies.
public struct ConnectOptions: Sendable {
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

    /// Application metadata that will be displayed in PowerSync service logs.
    ///
    /// Provide small, non-sensitive key/value pairs (for example: `appName`, `version`, `environment`) to
    /// help identify the client in logs and diagnostics. Do not include secrets or tokens.
    ///
    /// Example:
    /// ```swift
    /// ["appName": "MyApp", "version": "1.2.3"]
    /// ```
    public var appMetadata: [String: String]

    /// Uses a new sync client implemented in Rust instead of the one implemented in Kotlin.
    ///
    /// This option is enabled by default and recommended for all apps. The old Kotlin-based implementation
    /// will be removed in a future version of the SDK.
    public var newClientImplementation: Bool

    /// Configuration for the sync client used for PowerSync requests.
    ///
    /// Provides options to customize network behavior including logging of HTTP
    /// requests and responses. When `nil`, default HTTP client settings are used
    /// with no network logging.
    ///
    /// Set this to configure network logging or other HTTP client behaviors
    /// specific to PowerSync operations.
    ///
    /// - SeeAlso: `SyncClientConfiguration` for available configuration options
    public var clientConfiguration: SyncClientConfiguration?

    /// Initializes a `ConnectOptions` instance with optional values.
    ///
    /// - Parameters:
    ///   - crudThrottle: TimeInterval between CRUD operations in milliseconds. Defaults to `1` second.
    ///   - retryDelay: Delay TimeInterval between retry attempts in milliseconds. Defaults to `5` seconds.
    ///   - params: Custom sync parameters to send to the server. Defaults to an empty dictionary.
    ///   - clientConfiguration: Configuration for the HTTP client used to connect to PowerSync.
    public init(
        crudThrottle: TimeInterval = 1,
        retryDelay: TimeInterval = 5,
        params: JsonParam = [:],
        clientConfiguration: SyncClientConfiguration? = nil,
        appMetadata: [String: String] = [:]
    ) {
        self.crudThrottle = crudThrottle
        self.retryDelay = retryDelay
        self.params = params
        newClientImplementation = true
        self.clientConfiguration = clientConfiguration
        self.appMetadata = appMetadata
    }

    /// Initializes a ``ConnectOptions`` instance with optional values, including experimental options.
    @available(
        *,
        deprecated,
        message: "Specifying the newClientImplementation flag is no longer needed. It is now enabled by default. The use of the old client is deprecated and will be removed in a future version."
    )
    public init(
        crudThrottle: TimeInterval = 1,
        retryDelay: TimeInterval = 5,
        params: JsonParam = [:],
        newClientImplementation: Bool = true,
        clientConfiguration: SyncClientConfiguration? = nil,
        appMetadata: [String: String] = [:]
    ) {
        self.crudThrottle = crudThrottle
        self.retryDelay = retryDelay
        self.params = params
        self.newClientImplementation = newClientImplementation
        self.clientConfiguration = clientConfiguration
        self.appMetadata = appMetadata
    }
}

/// A PowerSync managed database.
///
/// Use one instance per database file.
///
/// Use `PowerSyncDatabase.connect` to connect to the PowerSync service, to keep the local database in sync with the remote database.
///
/// All changes to local tables are automatically recorded, whether connected or not. Once connected, the changes are uploaded.
public protocol PowerSyncDatabaseProtocol: Queries, Sendable {
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
        connector: PowerSyncBackendConnectorProtocol,
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

    /// Obtains an async iterator of completed transactions with local writes against the database.
    ///
    /// This is typically used from the ``PowerSyncBackendConnectorProtocol/uploadData(database:)`` callback.
    /// Each entry emitted by teh returned flow is a full transaction containing all local writes made while that transaction was
    /// active.
    ///
    /// Unlike ``getNextCrudTransaction()``, which always returns the oldest transaction that hasn't been
    /// ``CrudTransaction/complete()``d yet, this iterator can be used to upload multiple transactions.
    /// Calling ``CrudTransaction/complete()`` will mark that and all prior transactions returned by this iterator as
    /// completed.
    ///
    /// This can be used to upload multiple transactions in a single batch, e.g. with
    ///
    /// ```Swift
    ///
    /// ```
    func getCrudTransactions() -> any CrudTransactions

    /// Convenience method to get the current version of PowerSync.
    func getPowerSyncVersion() async throws -> String

    /// Close the sync connection.
    ///
    /// Use `connect` to connect again.
    func disconnect() async throws

    /// Disconnect and clear the database.
    ///
    /// Clearing the database is useful when a user logs out, to ensure another user logging in later would not see
    /// previous data.
    ///
    /// The database can still be queried after this is called, but the tables would be empty.
    ///
    /// To perserve data in local-only tables, set `clearLocal` to `false`.
    ///
    /// A `soft` clear deletes publicly visible data, but keeps internal copies of data synced in the database. This
    /// usually means that if the same user logs out and back in again, the first sync is very fast because all internal
    /// data is still available. When a different user logs in, no old data would be visible at any point.
    /// Using soft clears is recommended where it's not a security issue that old data could be reconstructed from
    /// the database.
    func disconnectAndClear(clearLocal: Bool, soft: Bool) async throws

    /// Create a ``SyncStream`` instance for the given name and parameters.
    ///
    /// Use ``SyncStream/subscribe`` on the returned instance to subscribe to the stream.
    func syncStream(name: String, params: JsonParam?) -> any SyncStream

    /// Close the database, releasing resources.
    /// Also disconnects any active connection.
    ///
    /// Once close is called, this database cannot be used again - a new one must be constructed.
    func close() async throws

    /// Close the database, releasing resources.
    /// Also disconnects any active connection.
    ///
    /// Once close is called, this database cannot be used again - a new one must be constructed.
    ///
    /// - Parameter deleteDatabase: Set to true to delete the SQLite database files. Defaults to `false`.
    ///
    /// - Throws: An error if a database file exists but could not be deleted. Files that don't exist are ignored.
    ///   This includes the main database file and any WAL mode files (.wal, .shm, .journal).
    func close(deleteDatabase: Bool) async throws
}

public extension PowerSyncDatabaseProtocol {
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
    func getNextCrudTransaction() async throws -> CrudTransaction? {
        for try await transaction in getCrudTransactions() {
            return transaction
        }

        return nil
    }

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
        connector: PowerSyncBackendConnectorProtocol,
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

    func disconnectAndClear() async throws {
        try await disconnectAndClear(clearLocal: true, soft: false)
    }

    func disconnectAndClear(clearLocal: Bool) async throws {
        try await disconnectAndClear(clearLocal: clearLocal, soft: false)
    }

    func disconnectAndClear(soft: Bool) async throws {
        try await disconnectAndClear(clearLocal: true, soft: soft)
    }

    func getCrudBatch(limit: Int32 = 100) async throws -> CrudBatch? {
        try await getCrudBatch(
            limit: limit
        )
    }
}
