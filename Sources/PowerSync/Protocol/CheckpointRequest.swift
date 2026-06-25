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
/// TOOD, better docs
public protocol CheckpointRequest: Sendable {
    /// Waits for the checkpoint to have been synced back
    /// TODO: Triggers a connection retry if currently in a back-off period
    /// Throws if a new sync error is reached or if a timeout has been reached.
    func waitForSync() async throws 
}