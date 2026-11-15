import Foundation

/// What PowerSync DevTools read from a database beyond the public API. Visible only to modules that
/// import PowerSync with `@_spi(PowerSyncDevTools)`.
@_spi(PowerSyncDevTools)
public extension PowerSyncDatabaseProtocol {
    private var impl: PowerSyncDatabaseImpl? { self as? PowerSyncDatabaseImpl }

    /// The schema the database currently uses.
    func devToolsSchema() async -> Schema? {
        guard let impl else { return nil }
        return await impl.schema.inner
    }

    /// The path of the database file, as passed when the database was opened.
    var devToolsDatabaseFilename: String? { impl?.databaseFilename }

    /// The options of the last `connect`, or `nil` before the first one.
    var devToolsConnectOptions: ConnectOptions? {
        impl?.lastConnection.withLock { $0?.options }
    }

    /// The credentials of the last connection, from the connector's cache when it has them.
    func devToolsCredentials() async -> PowerSyncCredentials? {
        guard let authenticator = impl?.lastConnection.withLock({ $0?.authenticator }) else { return nil }
        return try? await authenticator.fetchCredentials()
    }

    /// Connects again with the arguments of the last `connect`.
    func devToolsReconnect() async throws {
        guard let impl, let last = impl.lastConnection.withLock({ $0 }) else {
            throw PowerSyncError.operationFailed(
                message: "The database has not connected yet, so there is nothing to reconnect.",
                underlyingError: nil
            )
        }
        try await impl.connectInternal(
            authenticator: last.authenticator,
            uploader: last.uploader,
            checkpointRequests: last.checkpointRequests,
            options: last.options
        )
    }

    /// Calls `listener` with each core diagnostics event. Returns a function that removes it.
    func devToolsAddDiagnosticsListener(_ listener: @escaping @Sendable (JsonValue) -> Void) -> @Sendable () -> Void {
        guard let impl else { return {} }
        let id = UUID()
        impl.diagnosticsListeners.withLock { $0[id] = listener }
        return { impl.diagnosticsListeners.withLock { _ = $0.removeValue(forKey: id) } }
    }
}
