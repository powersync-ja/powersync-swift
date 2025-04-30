import OSLog

internal class PowerSyncBackendConnectorAdapter: KotlinPowerSyncBackendConnector {
    let swiftBackendConnector: PowerSyncBackendConnector
    let db: any PowerSyncDatabaseProtocol
    let logTag = "PowerSyncBackendConnector"
    
    init(
        swiftBackendConnector: PowerSyncBackendConnector,
        db: any PowerSyncDatabaseProtocol
    ) {
        self.swiftBackendConnector = swiftBackendConnector
        self.db = db
    }
    
    override func __fetchCredentials() async throws -> KotlinPowerSyncCredentials? {
        do {
            let result = try await swiftBackendConnector.fetchCredentials()
            return result?.kotlinCredentials
        } catch {
            db.logger.error("Error while fetching credentials", tag: logTag)
            /// We can't use throwKotlinPowerSyncError here since the Kotlin connector 
            /// runs this in a Job - this seems to break the SKIEE error propagation.
            /// returning nil here should still cause a retry
            return nil
        }
    }

    override func __uploadData(database: KotlinPowerSyncDatabase) async throws {
        do {
            // Pass the Swift DB protocal to the connector
            return try await swiftBackendConnector.uploadData(database: db)
        } catch {
            db.logger.error("Error while uploading data: \(error)", tag: logTag)
            // Relay the error to the Kotlin SDK
            try throwKotlinPowerSyncError(
                message: "Connector errored while uploading data: \(error.localizedDescription)",
                cause: error.localizedDescription,
            )
        }
    }
}
