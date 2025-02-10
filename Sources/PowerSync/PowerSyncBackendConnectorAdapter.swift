import OSLog

class PowerSyncBackendConnectorAdapter: KotlinPowerSyncBackendConnector {
    let swiftBackendConnector: PowerSyncBackendConnector

    init(
        swiftBackendConnector: PowerSyncBackendConnector
    ) {
        self.swiftBackendConnector = swiftBackendConnector
    }

    override func __fetchCredentials() async throws -> KotlinPowerSyncCredentials? {
        do {
            let result = try await swiftBackendConnector.fetchCredentials()
            return result?.kotlinCredentials
        } catch {
            if #available(iOS 14.0, *) {
                Logger().error("Failed to fetch credentials: \(error.localizedDescription)")
            } else {
                print("Failed to fetch credentials: \(error.localizedDescription)")
            }
            return nil
        }
    }

    override func __uploadData(database: KotlinPowerSyncDatabase) async throws {
        let swiftDatabase = KotlinPowerSyncDatabaseImpl(kotlinDatabase: database)
        do {
            return  try await swiftBackendConnector.uploadData(database: swiftDatabase)
        } catch {
            if #available(iOS 14.0, *) {
                Logger().error("Failed to upload data: \(error)")
            } else {
                print("Failed to upload data: \(error)")
            }
        }
    }
}
