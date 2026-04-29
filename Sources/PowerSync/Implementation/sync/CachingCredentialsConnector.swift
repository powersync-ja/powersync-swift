/// Wraps a ``PowerSyncBackendConnectorProtocol`` to cache and invalidate credentials. 
actor CachingCredentialsConnector {
    private let inner: PowerSyncBackendConnectorProtocol
    private var cachedCredentials: PowerSyncCredentials? = nil

    init(inner: PowerSyncBackendConnectorProtocol) {
        self.inner = inner
    }
    
    func fetchCredentials(allowCached: Bool = true) async throws -> PowerSyncCredentials? {
        if let credentials = self.cachedCredentials, allowCached {
            return credentials
        }
        
        let credentials = try await self.inner.fetchCredentials()
        self.cachedCredentials = credentials
        return credentials
    }
    
    func invalidateCachedCredentials() {
        self.cachedCredentials = nil
    }
    
    nonisolated func uploadData(database: any PowerSyncDatabaseProtocol) async throws {
        // Nonisolated because we don't want this to block fetching credentials.
        try await self.inner.uploadData(database: database)
    }
}
