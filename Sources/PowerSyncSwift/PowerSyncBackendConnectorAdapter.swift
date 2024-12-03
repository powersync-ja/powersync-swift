class PowerSyncBackendConnectorAdapter: KotlinPowerSyncBackendConnector {
    let swiftBackendConnector: PowerSyncBackendConnector

    init(
        swiftBackendConnector: PowerSyncBackendConnector
    ) {
        self.swiftBackendConnector = swiftBackendConnector
    }

    override func __fetchCredentials() async throws -> KotlinPowerSyncCredentials? {
        try await swiftBackendConnector.fetchCredentials()?.kotlinCredentials
    }

    override func __uploadData(database: KotlinPowerSyncDatabase) async throws {
        let swiftDatabase = KotlinPowerSyncDatabaseImpl(kotlinDatabase: database)
        try await swiftBackendConnector.uploadData(database: swiftDatabase)
    }
}
