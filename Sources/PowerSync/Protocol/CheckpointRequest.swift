import Foundation

/// Errors thrown while creating a checkpoint request.
public enum CheckpointRequestError: Error, LocalizedError {
    /// The target PowerSync service does not support checkpoint requests.
    /// Update the PowerSync service to use this API.
    case instanceNotSupported

    /// Checkpoint requests require an active or connecting sync client.
    ///
    /// A request made while disconnected would not be delivered to the PowerSync service,
    /// so it could never be observed in the sync stream.
    case notConnected

    /// The active connection was not configured to use checkpoint requests.
    ///
    /// Reconnect with ``ConnectOptions/checkpointMode`` set to ``CheckpointMode/requests`` before
    /// calling ``PowerSyncDatabaseProtocol/requestCheckpoint()``.
    case checkpointRequestsNotEnabled

    /// The checkpoint request could not be completed.
    case operationFailed(message: String? = nil, underlyingError: Error? = nil)

    public var errorDescription: String? {
        switch self {
        case .instanceNotSupported:
            return "The PowerSync service does not support checkpoint requests. Update the PowerSync service to use this API."
        case .notConnected:
            return "Checkpoint requests require an active or connecting sync client."
        case .checkpointRequestsNotEnabled:
            return "The active connection was not configured to use checkpoint requests. Connect with checkpointMode set to .requests."
        case .operationFailed(let message, let underlyingError):
            var description = "The checkpoint request could not be completed."
            if let message {
                description += " \(message)"
            }
            if let underlyingError {
                description += " (\(underlyingError))"
            }
            return description
        }
    }
}

/// Errors thrown while waiting for a checkpoint request to sync.
public enum CheckpointWaitError: Error, LocalizedError {
    /// The checkpoint request was not synced before the timeout elapsed.
    case timeout

    /// The sync client disconnected before the checkpoint request was synced.
    case disconnected

    /// The sync status stream ended before the checkpoint request was synced.
    case syncStatusClosed

    /// The sync client reported a download or upload error while waiting.
    case errorDetected(message: String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "The checkpoint request was not synced before the timeout elapsed."
        case .disconnected:
            return "The sync client disconnected before the checkpoint request was synced."
        case .syncStatusClosed:
            return "The sync status stream ended before the checkpoint request was synced."
        case .errorDetected(let message):
            return "The sync client reported an error while waiting for the checkpoint request: \(message)"
        }
    }
}

/// A checkpoint request created by ``PowerSyncDatabaseProtocol/requestCheckpoint()``.
///
/// Use this value to wait until the local database has applied server-side changes up to
/// the requested checkpoint. This is useful for explicit refresh flows where the caller
/// wants confirmation that the local view has caught up to the service.
public protocol CheckpointRequest: Sendable {
    /// Whether this checkpoint has already been synced locally.
    ///
    /// This is a snapshot of checkpoint request events observed by the sync client.
    /// Use ``waitForSync()`` or ``waitForSync(timeout:)`` to suspend until the checkpoint is reached.
    var isSynced: Bool { get }
    
    /// Waits until this checkpoint has been synced locally.
    ///
    /// This method observes sync-loop checkpoint application events for an already-created
    /// checkpoint request.
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
