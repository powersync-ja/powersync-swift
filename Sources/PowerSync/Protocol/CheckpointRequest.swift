import Foundation

/// Errors thrown while creating a checkpoint request.
public enum CheckPointRequestError: Error, LocalizedError {
    /// The target PowerSync service does not support checkpoint requests.
    /// Update the PowerSync service to use this API.
    case instanceNotSupported

    /// Checkpoint requests require an active or connecting sync client.
    ///
    /// A request made while disconnected would not be delivered to the PowerSync service,
    /// so it could never be observed in the sync stream.
    case notConnected

    /// The PowerSync service rejected the checkpoint request because the current credentials are not valid.
    case unauthenticated(message: String)

    /// The checkpoint request could not be completed.
    case operationFailed(message: String? = nil, underlyingError: Error? = nil)
}

/// Errors thrown while waiting for a checkpoint request to sync.
public enum CheckpointWaitError: Error, LocalizedError {
    /// The checkpoint request was not synced before the timeout elapsed.
    case timeout

    /// The sync status stream ended before the checkpoint request was synced.
    case syncStatusClosed

    /// The sync client reported a download or upload error while waiting.
    case errorDetected(error: Sendable)
}

/// A checkpoint request created by ``PowerSyncDatabaseProtocol/requestCheckpoint()``.
///
/// Use this value to wait until the local database has applied server-side changes up to
/// the requested checkpoint. This is useful for explicit refresh flows where the caller
/// wants confirmation that the local view has caught up to the service.
public protocol CheckpointRequest: Sendable {
    /// Whether this checkpoint has already been synced locally.
    ///
    /// This is a snapshot of the current sync status. Use ``waitForSync()`` or
    /// ``waitForSync(timeout:)`` to suspend until the checkpoint is reached.
    var isSynced: Bool { get }
    
    /// Waits until this checkpoint has been synced locally.
    ///
    /// This method observes sync status updates for an already-created checkpoint request.
    /// - Throws: ``CheckpointWaitError`` when the sync status stream closes before the
    ///   checkpoint is reached, or when a sync error is present or reached while waiting.
    func waitForSync() async throws

    /// Waits until this checkpoint has been synced locally, or until a timeout elapses.
    ///
    /// - Parameter timeout: The maximum number of seconds to wait.
    /// - Throws: ``CheckpointWaitError/timeout`` if the checkpoint was not synced before the timeout.
    ///   Also throws if a sync error is present or reached while waiting.
    func waitForSync(timeout: TimeInterval) async throws
}

public extension CheckpointRequest {
    func waitForSync(timeout: TimeInterval) async throws {
        if isSynced {
            return
        }

        if timeout <= 0 {
            throw CheckpointWaitError.timeout
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }

            group.addTask {
                try await waitForSync()
            }

            group.addTask {
                do {
                    try await sleepForSeconds(seconds: timeout)
                } catch is CancellationError {
                    return
                }

                throw CheckpointWaitError.timeout
            }

            let _ = try await group.next()
            try Task.checkCancellation()
        }
    }
}
