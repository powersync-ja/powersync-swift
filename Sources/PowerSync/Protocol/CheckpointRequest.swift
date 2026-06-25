import Foundation

public enum CheckPointRequestError: Error, LocalizedError {
    /// The target PowerSync service does not support checkpoint requests.
    /// Please update the PowerSync service version
    case instanceNotSupported

    /// The creation of a checkpoint request requires the client to either
    /// be connected or connecting. Checkpoint Requests wont ever resolve while offline.
    case notConnected

    /// The request to the PowerSync service instance could not be completed due to authentication issues.
    case unauthenticated(message: String)

    /// Represents a failure in an operation
    case operationFailed(message: String? = nil, underlyingError: Error? = nil)
}

///
public enum CheckpointWaitError: Error, LocalizedError {
    /// A checkpoint request was not synced in the specified period
    case timeout

    /// A sync error (download or upload was reached) while waiting
    case errorDetected(error: Sendable)
}

/// Result from calling db.requestCheckpoint
/// TODO: Better docs.
public protocol CheckpointRequest: Sendable {
    /// If the checkpoint has been synced
    var isSynced: Bool { get }
    
    /// Waits for the checkpoint to have been synced back
    /// TODO: Triggers a connection retry if currently in a back-off period
    /// Throws if a new sync error is reached.
    func waitForSync() async throws

    /// Waits for the checkpoint to have been synced back.
    ///
    /// - Parameter timeout: The maximum number of seconds to wait.
    /// - Throws: ``CheckpointWaitError/timeout`` if the checkpoint was not synced before the timeout.
    ///   Also throws if a new sync error is reached while waiting.
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

            do {
                let _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
