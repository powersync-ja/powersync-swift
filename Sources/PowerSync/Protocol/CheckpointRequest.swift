import Foundation

/// A common type for the errors thrown by the checkpoint request APIs.
///
/// Both ``CheckpointRequestError`` (thrown while creating a request) and ``CheckpointWaitError``
/// (thrown while waiting for one to sync) conform to this protocol. A caller that drives both
/// steps in a single `do` block can catch them together as `catch let error as any CheckpointError`,
/// while still switching on the concrete type when it needs to distinguish the two.
///
/// > Warning: Checkpoint requests are an alpha API. It may change in future releases.
public protocol CheckpointError: Error, LocalizedError {}

/// Errors thrown while creating a checkpoint request.
///
/// > Warning: Checkpoint requests are an alpha API. It may change in future releases.
public enum CheckpointRequestError: CheckpointError {
    /// The target PowerSync service does not support checkpoint requests.
    /// Update to PowerSync service version 1.24.0 or later to use this API.
    case instanceNotSupported

    /// Checkpoint requests require an active or connecting sync client.
    ///
    /// A request made without an active or connecting sync client would not be delivered to the
    /// PowerSync service, so it could never be observed in the sync stream.
    case notConnecting

    /// The active connection was not configured to use checkpoint requests.
    ///
    /// Reconnect with ``ConnectOptions/checkpointMode`` set to `.requests()` before
    /// calling ``PowerSyncDatabaseProtocol/requestCheckpoint()``.
    case checkpointRequestsNotEnabled

    /// The checkpoint request could not be completed.
    case operationFailed(message: String? = nil, underlyingError: Error? = nil)

    public var errorDescription: String? {
        switch self {
        case .instanceNotSupported:
            return "The PowerSync service does not support checkpoint requests. Update to PowerSync service version 1.24.0 or later to use this API."
        case .notConnecting:
            return "Checkpoint requests require an active or connecting sync client."
        case .checkpointRequestsNotEnabled:
            return "The active connection was not configured to use checkpoint requests. Connect with checkpointMode set to .requests()."
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
///
/// > Warning: Checkpoint requests are an alpha API. It may change in future releases.
public enum CheckpointWaitError: CheckpointError {
    /// The checkpoint request was not synced before the timeout elapsed.
    case timeout

    /// The sync client disconnected before the checkpoint request was synced.
    ///
    /// The checkpoint request itself remains valid: request IDs are persisted by the core
    /// extension, so ``CheckpointRequest/waitForSync()`` can be called again after reconnecting.
    case disconnected

    /// The sync client reported a download or upload error while waiting.
    case errorDetected(message: String)

    /// The active connection was not configured to use checkpoint requests.
    ///
    /// This happens when the connection that created the request has been replaced by one
    /// connected without ``ConnectOptions/checkpointMode`` set to `.requests()`.
    case checkpointRequestsNotEnabled

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "The checkpoint request was not synced before the timeout elapsed."
        case .disconnected:
            return "The sync client disconnected before the checkpoint request was synced."
        case .errorDetected(let message):
            return "The sync client reported an error while waiting for the checkpoint request: \(message)"
        case .checkpointRequestsNotEnabled:
            return "The active connection was not configured to use checkpoint requests. Connect with checkpointMode set to .requests()."
        }
    }
}

/// A checkpoint request created by ``PowerSyncDatabaseProtocol/requestCheckpoint()``.
///
/// Use this value to wait until the local database has applied server-side changes up to
/// the requested checkpoint. This is useful for explicit refresh flows where the caller
/// wants confirmation that the local view has caught up to the service.
///
/// The request is tracked against the database, not a single connection: request IDs are
/// persisted by the core extension, so this value stays usable across disconnect/reconnect
/// cycles. A wait interrupted by a disconnect throws ``CheckpointWaitError/disconnected``,
/// but the same request can be awaited again once a new connection is established.
///
/// Requests do not survive ``PowerSyncDatabaseProtocol/disconnectAndClear(clearLocal:soft:)``:
/// clearing the database resets the request counter, so instances created before a clear
/// should be discarded and requested again.
///
/// > Warning: Checkpoint requests are an alpha API. It may change in future releases.
public protocol CheckpointRequest: Sendable {
    /// Whether this checkpoint request has synced before.
    ///
    /// Use ``waitForSync()`` or ``waitForSync(timeout:)`` to suspend until the checkpoint is reached.
    var hasSynced: Bool { get }

    /// Waits until this checkpoint has been synced locally.
    ///
    /// This method observes sync-loop checkpoint application events for an already-created
    /// checkpoint request, using the currently active sync client.
    ///
    /// This fails fast on sync errors: if a download or upload error is already present when the
    /// wait begins — not only if one occurs while waiting — it throws
    /// ``CheckpointWaitError/errorDetected(message:)`` immediately, even when the error is
    /// transient. Since the client cannot know whether such an error is directly recoverable, retry the
    /// wait once sync has recovered.
    /// - Throws: ``CheckpointWaitError`` when no sync client is active, when the sync client
    ///   disconnects before the checkpoint is reached, or when a sync error is present or reached
    ///   while waiting. Throws ``CheckpointWaitError/checkpointRequestsNotEnabled``
    ///   when the active connection was not configured with `.requests()`.
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
        if hasSynced {
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
