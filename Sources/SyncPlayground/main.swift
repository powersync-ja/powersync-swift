import Foundation
import PowerSync

func start() async throws {
    let schema = Schema(tables: [])
    let db = PowerSyncDatabase(schema: schema)
    
    try await db.connect(connector: TestConnector(), options: ConnectOptions())
    print("Is connected!")
    
    try await db.waitForFirstSync()
}

final class TestConnector: PowerSyncBackendConnectorProtocol {
    func fetchCredentials() async throws -> PowerSync.PowerSyncCredentials? {
        let url = URL(string: "http://localhost:6060/api/auth/token")!
        let (data, _) = try await URLSession.shared.data(from: url)
        
        struct Response: Decodable {
            let token: String
        }
        
        let response = try JSONDecoder().decode(Response.self, from: data)
        return PowerSyncCredentials(
            endpoint: "http://localhost:8080",
            token: response.token
        )
    }
    
    func uploadData(database: any PowerSync.PowerSyncDatabaseProtocol) async throws {
        throw PowerSyncError.operationFailed(message: "todo: uploadData")
    }
}

let _ = try await start()
