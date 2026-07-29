import Foundation
import PowerSync

// A small command line demo for custom checkpoint requests: local writes are uploaded to the
// Node.js demo backend, which also receives the checkpoint requests used to confirm that the
// local database has caught up to the server-side state.

let environment = ProcessInfo.processInfo.environment
guard let backendUrl = URL(string: environment["BACKEND_URL"] ?? "http://localhost:6060") else {
    fatalError("BACKEND_URL is not a valid URL")
}
let defaultPowerSyncUrl = "http://localhost:8080"
let powerSyncUrl = environment["POWERSYNC_URL"] ?? defaultPowerSyncUrl
let defaultUserId = "00000000-0000-4000-8000-000000000001"
let userId = resolveUserId(environment["USER_ID"], defaultUserId: defaultUserId)
// Use stdout so debug logs are visible when running this command-line demo.
let logger = DefaultLogger(minSeverity: .debug, writers: [StdoutLogWriter()])

let db = PowerSyncDatabase(
    schema: AppSchema,
    dbFilename: ":memory:",
    logger: logger
)
let connector = NodeConnector(
    backendUrl: backendUrl,
    powerSyncUrl: powerSyncUrl,
    userId: userId,
    logger: logger
)

if environment["POWERSYNC_URL"] == nil {
    print("Connecting to PowerSync at \(powerSyncUrl) (default), uploading to backend at \(backendUrl)")
} else {
    print("Connecting to PowerSync at \(powerSyncUrl), uploading to backend at \(backendUrl)")
}
print("Using user ID \(userId) with an in-memory local database")

let syncErrorMonitor = monitorSyncErrors(db.currentStatus)
defer {
    syncErrorMonitor.cancel()
}

try await db.connect(
    connector: connector,
    options: ConnectOptions(checkpointMode: .requests())
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

private func monitorSyncErrors(_ status: any SyncStatus) -> Task<Void, Never> {
    Task {
        var previousDownloadError: String?
        var previousUploadError: String?

        for await update in status.asFlow() {
            reportSyncError(update.downloadError, label: "download", previousError: &previousDownloadError)
            reportSyncError(update.uploadError, label: "upload", previousError: &previousUploadError)
        }
    }
}

private func resolveUserId(_ configuredUserId: String?, defaultUserId: String) -> String {
    guard let configuredUserId, !configuredUserId.isEmpty else {
        return defaultUserId
    }

    guard UUID(uuidString: configuredUserId) != nil else {
        print("Ignoring USER_ID=\(configuredUserId); the Node.js todo backend expects a UUID. Using \(defaultUserId).")
        return defaultUserId
    }

    return configuredUserId
}

private func reportSyncError(_ error: Any?, label: String, previousError: inout String?) {
    guard let error else {
        previousError = nil
        return
    }

    let message = String(describing: error)
    guard message != previousError else {
        return
    }

    previousError = message
    print("Sync \(label) error: \(message)")
}

private final class StdoutLogWriter: LogWriterProtocol {
    func log(severity: LogSeverity, message: String, tag: String?) {
        let tagPrefix = tag.map { !$0.isEmpty ? "[\($0)] " : "" } ?? ""
        print("\(severity.stringValue): \(tagPrefix)\(message)")
    }
}
