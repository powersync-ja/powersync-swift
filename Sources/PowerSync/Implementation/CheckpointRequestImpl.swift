/// Tracks a checkpoint request against the active database group rather than the sync client
/// it was created from.
///
/// Checkpoint request IDs are persisted by the core extension and are monotonic across
/// connections, and every new sync client re-seeds the last applied request ID on connect.
/// Resolving the active client through the group's ``SyncCoordinator`` on each call therefore
/// keeps this object usable across disconnect/reconnect cycles instead of pinning a client
/// whose signals are torn down on disconnect.
final class CheckpointRequestImpl: CheckpointRequest {
    private let requestId: Int64
    private let group: ActiveDatabaseGroup
    /// A checkpoint request stays applied once core has applied it locally, so `isSynced`
    /// remains true even while disconnected.
    private let wasSynced = Mutex(false)

    init(requestId: Int64, group: ActiveDatabaseGroup) {
        self.requestId = requestId
        self.group = group
    }

    var isSynced: Bool {
        wasSynced.withLock { synced in
            if !synced {
                synced = group.syncCoordinator.syncClient?.isCheckpointRequestApplied(requestId) ?? false
            }
            return synced
        }
    }

    func waitForSync() async throws {
        if isSynced {
            return
        }

        try await group.syncCoordinator.guardNotConnected(
            inner: {
                throw CheckpointWaitError.disconnected
            },
            ifConnected: { client in
                guard client.checkpointMode == .requests else {
                    throw CheckpointRequestError.checkpointRequestsNotEnabled
                }
                try await client.waitForCheckpointRequest(requestId)
            }
        )
        wasSynced.withLock { $0 = true }
    }
}
