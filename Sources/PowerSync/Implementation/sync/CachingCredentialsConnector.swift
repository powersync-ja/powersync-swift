actor CachingCredentialsConnector {
    private let inner: PowerSyncBackendConnectorProtocol
    private var cachedCredentials: PowerSyncCredentials? = nil

    init(inner: PowerSyncBackendConnectorProtocol) {
        self.inner = inner
    }
    
    func fetchCredentials() async throws -> PowerSyncCredentials? {
        if let credentials = self.cachedCredentials {
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
        try await self.inner.uploadData(database: database)
    }
}
