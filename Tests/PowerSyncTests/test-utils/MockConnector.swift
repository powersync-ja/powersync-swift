import PowerSync

final class MockConnector: PowerSyncBackendConnectorProtocol {
    func fetchCredentials() async throws -> PowerSync.PowerSyncCredentials? {
        return nil
    }

    func uploadData(database _: any PowerSync.PowerSyncDatabaseProtocol) async throws {}
}
