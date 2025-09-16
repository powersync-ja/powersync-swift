import OSLog
import PowerSyncKotlin

final class SwiftBackendConnectorBridge: KotlinSwiftBackendConnector, Sendable {
    let swiftBackendConnector: PowerSyncBackendConnectorProtocol
    let db: any PowerSyncDatabaseProtocol
    let logTag = "PowerSyncBackendConnector"

    init(
        swiftBackendConnector: PowerSyncBackendConnectorProtocol,
        db: any PowerSyncDatabaseProtocol
    ) {
        self.swiftBackendConnector = swiftBackendConnector
        self.db = db
    }
    
    func __fetchCredentials() async throws -> PowerSyncResult {
        do {
            let result = try await swiftBackendConnector.fetchCredentials()
            return PowerSyncResult.Success(value: result?.kotlinCredentials)
        } catch {
            db.logger.error("Error while fetching credentials", tag: logTag)
            return PowerSyncResult.Failure(exception: error.toPowerSyncError())
        }
    }
    
    func __uploadData() async throws -> PowerSyncResult {
        do {
            // Pass the Swift DB protocal to the connector
            try await swiftBackendConnector.uploadData(database: self.db)
            return PowerSyncResult.Success(value: nil)
        } catch {
            db.logger.error("Error while uploading data: \(error)", tag: logTag)
            return PowerSyncResult.Failure(exception: error.toPowerSyncError())
        }
    }
}
