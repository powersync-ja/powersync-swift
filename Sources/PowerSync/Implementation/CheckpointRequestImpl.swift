final class CheckpointRequestImpl: CheckpointRequest {
    private let requestId: Int64
    private let status: any SyncStatus

    init(requestId: Int64, db: any PowerSyncDatabaseProtocol) {
        self.requestId = requestId
        self.status = db.currentStatus
    }

    var isSynced: Bool {
        Self.isSynced(status: status, requestId: requestId)
    }

    func waitForSync() async throws {
        if isSynced {
            return
        }

        for await update in status.asFlow() {
            if Self.isSynced(status: update, requestId: requestId) {
                return
            }

            if let error = update.anyError {
                throw CheckpointWaitError.errorDetected(error: String(describing: error))
            }
        }
    }

    private static func isSynced(status: any SyncStatusData, requestId: Int64) -> Bool {
        guard let lastId = status.lastSyncedCheckpointRequestId else {
            return false
        }

        return lastId >= requestId
    }
}
