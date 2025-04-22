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
            return nil
        }
    }

    override func __uploadData(database: KotlinPowerSyncDatabase) async throws {
        do {
            // Pass the Swift DB protocal to the connector
            return  try await swiftBackendConnector.uploadData(database: db)
        } catch {
            db.logger.error("Error while uploading data: \(error)", tag: logTag)
        }
    }
}
