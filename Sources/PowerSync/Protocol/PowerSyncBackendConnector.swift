/// Authenticates the PowerSync SDK against a PowerSync service, allowing it to download
/// changes.
public protocol Authenticator: Sendable {
    /// Resolves a JWT to use when connecting to a PowerSync service.
    /// 
    /// The SDK does not cache this value and will call this method multiple times while a
    /// database is connected. Implementations should consider caching credentials.
    func resolveCredentials() async throws -> String
    /// Invoked by the SDK when the PowerSync service has rejected credentials previously
    /// returned yb ``Authenticator//resolveCredentials``.
    /// 
    /// If the ocnnector returns cached tokens, it can use this as a hint to refresh its local
    /// state.
    func invalidateCredentials() async
}

extension Authenticator {
    public func invalidateCredentials() {}
}

/// Uploads local mutations (from `INSERT`, `UPDATE` and `DELETE` statements against the
/// local database) to your source database.
/// 
/// While simple cases might use a protocol like PostgREST to write directly into the database,
/// a custom backend is commonly used to validate uploaded mutations.
public typealias MutationUploader = @Sendable (PowerSyncDatabaseProtocol) async throws -> ()

/// Implement this to connect an app backend.
///
/// The connector is responsible for:
/// 1. Creating credentials for connecting to the PowerSync service.
/// 2. Applying local changes against the backend application server.
/// 
/// A connector is an protocol combining both ``Authenticator`` and ``MutationUploader``.
/// Implementing these protocols directly might simplify their implementation, and allows connecting
/// in download-only or upload-only mode.
public protocol PowerSyncBackendConnectorProtocol: Authenticator, Sendable {
    /// Get credentials for PowerSync.
    ///
    /// This should always fetch a fresh set of credentials - don't use cached
    /// values.
    ///
    /// Return null if the user is not signed in. Throw an error if credentials
    /// cannot be fetched due to a network error or other temporary error.
    ///
    /// This token is kept for the duration of a sync connection.
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

// Default implementation of Authenticator and MutationUploader for existing PowerSyncBackendConnectors.
extension PowerSyncBackendConnectorProtocol {
    public func resolveCredentials() async throws -> String {
        guard let credentials = try await self.fetchCredentials() else {
            throw PowerSyncError.operationFailed(message: "User is not signed in (fetchCredentials returned nil)", underlyingError: nil)
        }
        return credentials.description
    }

    public func uploadMutations(_ onDatabase: any PowerSyncDatabaseProtocol) async throws {
        try await self.uploadData(database: onDatabase)
    }
}

/// A ``PowerSyncBackendConnectorProtocol`` that posts checkpoint requests to a custom backend
/// instead of the PowerSync service's `/sync/checkpoint-request` endpoint.
///
/// Implement this when uploads are processed asynchronously by the backend (for example through
/// a message queue): the sync client generates a checkpoint request ID and hands it to the
/// backend, which is responsible for creating a matching checkpoint once the uploads preceding
/// the request have been processed.
///
/// Connect with `.requests()` to use this connector's checkpoint requests.
/// In ``CheckpointMode/legacy`` mode this protocol is ignored and a warning is logged.
/// Checkpoint requests require PowerSync service version 1.24.0 or later, including
/// when this connector posts the requests through a custom backend.
///
/// > Warning: Checkpoint requests are an alpha API. It may change in future releases.
public protocol CustomCheckpointRequestConnector: Authenticator {
    /// Posts a client-generated checkpoint request to the backend and returns the effective
    /// checkpoint request state.
    ///
    /// Requests are scoped to the PowerSync client ID and are idempotent: the same ID may be
    /// posted multiple times (for example when reconnecting), and a new request replaces any
    /// previous one for the same client.
    ///
    /// The returned value is the checkpoint request state the backend accepted. This is
    /// usually the posted ID, but a backend must return its currently recorded state when
    /// that is newer (for example when the local database was cleared and the client restarts
    /// its request counter).
    ///
    /// Any thrown errors are treated like other sync errors: the sync iteration fails and is
    /// retried after the configured retry delay.
    ///
    /// Throw a ``CheckpointRequestError`` to control the error reported by checkpoint requests.
    /// Other thrown errors are wrapped as
    /// ``CheckpointRequestError/operationFailed(message:underlyingError:)``.
    ///
    /// This method is called independently from ``fetchCredentials()`` and does not receive the
    /// PowerSync token used internally for sync. If the checkpoint request endpoint requires
    /// application backend authentication, the connector should fetch or cache its own token for
    /// this request.
    /// - Parameters:
    ///   - checkpointRequestId: The client-generated checkpoint request ID.
    ///   - clientId: The PowerSync client ID this request is scoped to.
    func postCheckpointRequest(_ checkpointRequestId: Int64, clientId: String) async throws -> Int64
}

@available(*, deprecated, message: "PowerSyncBackendConnector is deprecated. Please implement PowerSyncBackendConnectorProtocol directly in your own class.")
open class PowerSyncBackendConnector: PowerSyncBackendConnectorProtocol,
    // This class is non-final, implementations should strictly conform to Sendable
    @unchecked Sendable
{
    public init() {}

    open func fetchCredentials() async throws -> PowerSyncCredentials? {
        return nil
    }

    open func uploadData(database _: PowerSyncDatabaseProtocol) async throws {}
}
