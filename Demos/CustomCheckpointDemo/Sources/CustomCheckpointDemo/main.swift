import Foundation
import PowerSync

// A small command line demo for custom checkpoint requests: local writes are uploaded to the
// Node.js demo backend, which also receives the checkpoint requests used to confirm that the
// local database has caught up to the server-side state.

let environment = ProcessInfo.processInfo.environment
guard let backendUrl = URL(string: environment["BACKEND_URL"] ?? "http://localhost:6060") else {
    fatalError("BACKEND_URL is not a valid URL")
}
let powerSyncUrl = environment["POWERSYNC_URL"]
let userId = environment["USER_ID"] ?? "UserID"

let db = PowerSyncDatabase(
    schema: AppSchema,
    dbFilename: "custom-checkpoint-demo.sqlite"
)
let connector = NodeConnector(
    backendUrl: backendUrl,
    powerSyncUrl: powerSyncUrl,
    userId: userId
)

if let powerSyncUrl {
    print("Connecting to PowerSync at \(powerSyncUrl), uploading to backend at \(backendUrl)")
} else {
    print("Connecting with PowerSync endpoint from backend token response, uploading to backend at \(backendUrl)")
}
try await db.connect(
    connector: connector,
    options: ConnectOptions(checkpointMode: .requests)
)

print("Waiting for first sync...")
try await db.waitForFirstSync()

// Make a local write, which the sync client uploads through the connector.
let listName = "Custom checkpoint demo \(Date())"
try await db.execute(
    sql: "INSERT INTO \(LISTS_TABLE) (id, name, created_at, owner_id) VALUES (uuid(), ?, datetime(), ?)",
    parameters: [listName, userId]
)
print("Inserted list: \(listName)")

// Request a checkpoint and wait until the local database has applied server-side changes up
// to it. The connector also receives write checkpoint requests created by the upload loop.
let checkpoint = try await db.requestCheckpoint()
try await checkpoint.waitForSync(timeout: 30)
print("Checkpoint applied - the local database is up to date with the server.")

let listCount = try await db.get(
    sql: "SELECT COUNT(*) FROM \(LISTS_TABLE)",
    parameters: []
) { try $0.getInt64(index: 0) }
print("Lists in the local database: \(listCount)")

try await db.disconnect()
try await db.close()
