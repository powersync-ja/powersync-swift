public protocol PowerSyncBackendConnectorProtocol: Sendable {
    ///
    /// Get credentials for PowerSync.
    ///
    /// This should always fetch a fresh set of credentials - don't use cached
    /// values.
    ///
    /// Return null if the user is not signed in. Throw an error if credentials
    /// cannot be fetched due to a network error or other temporary error.
    ///
    /// This token is kept for the duration of a sync connection.
    ///
    func fetchCredentials() async throws -> PowerSyncCredentials?

    ///
    /// Upload local changes to the app backend.
    ///
    /// Use [getCrudBatch] to get a batch of changes to upload.
    ///
    /// Any thrown errors will result in a retry after the configured wait period (default: 5 seconds).
    ///
    func uploadData(database: PowerSyncDatabaseProtocol) async throws
}

/// Implement this to connect an app backend.
///
/// The connector is responsible for:
/// 1. Creating credentials for connecting to the PowerSync service.
/// 2. Applying local changes against the backend application server.
///
@MainActor
open class PowerSyncBackendConnector: PowerSyncBackendConnectorProtocol {
    public init() {}

    open func fetchCredentials() async throws -> PowerSyncCredentials? {
        return nil
    }

    open func uploadData(database _: PowerSyncDatabaseProtocol) async throws {}
}
