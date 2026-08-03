/// Tracks a checkpoint request against the active database group rather than the sync client
/// it was created from.
///
/// Checkpoint request IDs are persisted by the core extension and are monotonic across
/// connections, and every new sync client re-seeds the last requested request ID on connect.
/// Resolving the active client through the group's ``SyncCoordinator`` on each call therefore
/// keeps this object usable across disconnect/reconnect cycles instead of pinning a client
/// from an earlier connection.
final class CheckpointRequestImpl: CheckpointRequest {
    private let requestId: Int64
    private let db: PowerSyncDatabaseImpl
    /// A checkpoint request stays applied once core has applied it locally, so `hasSynced`
    /// remains true even while disconnected.
    private let wasSynced = Mutex(false)

    init(requestId: Int64, db: PowerSyncDatabaseImpl) {
        self.requestId = requestId
        self.db = db
    }

    var hasSynced: Bool {
        wasSynced.withLock { synced in
            if !synced {
                synced = db.syncStatus.isCheckpointRequestApplied(requestId)
            }
            return synced
        }
    }

    func waitForSync() async throws {
        if hasSynced {
            return
        }

        try await db.group.syncCoordinator.guardNotConnected(
            inner: {
                throw CheckpointWaitError.disconnected
            },
            ifConnected: { client in
                guard case .requests = client.checkpointMode else {
                    throw CheckpointWaitError.checkpointRequestsNotEnabled
                }
            }
        )

        try await waitForCheckpointRequest()
        wasSynced.withLock { $0 = true }
    }

    /// Waits until sync status reports that this checkpoint request has been applied.
    private func waitForCheckpointRequest() async throws {
        if db.syncStatus.isCheckpointRequestApplied(requestId) {
            return
        }

        for await update in db.syncStatus.asFlow() {
            if db.syncStatus.isCheckpointRequestApplied(requestId) {
                return
            }

            if let error = update.anyError {
                // `asFlow()` emits the current status first. We intentionally fail fast if the
                // sync client is already in an error state when the caller starts waiting.
                throw CheckpointWaitError.errorDetected(message: String(describing: error))
            }

            if !update.connected && !update.connecting {
                throw CheckpointWaitError.disconnected
            }
        }

        // `asFlow()` is a non-throwing `AsyncStream`: cancelling the waiting task terminates the
        // iteration instead of throwing, so cancellation has to be reported explicitly. Without
        // this, a cancelled wait would be indistinguishable from a disconnect.
        try Task.checkCancellation()

        throw CheckpointWaitError.disconnected
    }
}
