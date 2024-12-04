public protocol PowerSyncBackendConnectorProtocol {
    func uploadData(database: PowerSyncDatabaseProtocol) async throws

    func fetchCredentials() async throws -> PowerSyncCredentials?
}

open class PowerSyncBackendConnector: PowerSyncBackendConnectorProtocol {
    public init() {}
    
    open func uploadData(database: PowerSyncDatabaseProtocol) async throws {}

    open func fetchCredentials() async throws -> PowerSyncCredentials? {
        return nil
    }
}

