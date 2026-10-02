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
}

enum InternalAuthenticator {
    case legacy(CachingCredentialsConnector)
    case endpointAndAuthenticator(
        endpoint: String,
        authenticator: Authenticator,
    )
}

extension InternalAuthenticator {
    func fetchCredentials() async throws -> PowerSyncCredentials? {
        switch self {
        case .legacy(let connector):
            return try await connector.fetchCredentials()
        case .endpointAndAuthenticator(let endpoint, let authenticator):
            let token = try await authenticator.resolveCredentials();
            return PowerSyncCredentials(
                endpoint: endpoint,
                token: token
            )
        }
    }

    func invalidateCredentials() async {
        switch self {
        case .legacy(let connector):
            await connector.invalidateCachedCredentials()
        case .endpointAndAuthenticator(endpoint: _, authenticator: let authenticator):
            await authenticator.invalidateCredentials()
        }
    }

    func prefetchCredentials() async throws {
        switch self {
        case .legacy(let connector):
            let _ = try await connector.fetchCredentials(allowCached: false)
        case .endpointAndAuthenticator(endpoint: _, authenticator: let authenticator):
            await authenticator.invalidateCredentials()
            let _ = try await authenticator.resolveCredentials()
        }
    }
}
