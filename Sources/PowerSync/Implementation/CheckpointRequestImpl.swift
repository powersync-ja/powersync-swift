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

        // Status updates contain the latest checkpoint request id applied by the core
        // extension. Once it catches up to this request id, all changes covered by the
        // checkpoint have been applied locally.
        for await update in status.asFlow() {
            if Self.isSynced(status: update, requestId: requestId) {
                return
            }

            if let error = update.anyError {
                // `asFlow()` emits the current status first. We intentionally fail fast if the
                // sync client is already in an error state when the caller starts waiting.
                throw CheckpointWaitError.errorDetected(error: String(describing: error))
            }
        }

        throw CheckpointWaitError.syncStatusClosed
    }

    private static func isSynced(status: any SyncStatusData, requestId: Int64) -> Bool {
        guard let lastId = status.lastSyncedCheckpointRequestId else {
            return false
        }

        return lastId >= requestId
    }
}
