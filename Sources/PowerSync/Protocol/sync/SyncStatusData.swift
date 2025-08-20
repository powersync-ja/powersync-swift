import Foundation

/// A protocol representing the synchronization status of a system, providing various indicators and error states.
public protocol SyncStatusData {
    /// Indicates whether the system is currently connected.
    var connected: Bool { get }

    /// Indicates whether the system is in the process of connecting.
    var connecting: Bool { get }

    /// Indicates whether the system is actively downloading changes.
    var downloading: Bool { get }

    /// Realtime progress information about downloaded operations during an active sync.
    ///
    /// For more information on what progress is reported, see ``SyncDownloadProgress``.
    /// This value will be non-null only if ``downloading`` is `true`.
    var downloadProgress: SyncDownloadProgress? { get }

    /// Indicates whether the system is actively uploading changes.
    var uploading: Bool { get }

    /// The date and time when the last synchronization was fully completed, if any.
    var lastSyncedAt: Date? { get }

    /// Indicates whether there has been at least one full synchronization.
    /// - Note: This value is `nil` when the state is unknown, for example, when the state is still being loaded.
    var hasSynced: Bool? { get }

    /// Represents any error that occurred during uploading.
    /// - Note: This value is cleared on the next successful upload.
    var uploadError: Any? { get }

    /// Represents any error that occurred during downloading (including connecting).
    /// - Note: This value is cleared on the next successful data download.
    var downloadError: Any? { get }

    /// A convenience property that returns either the `downloadError` or `uploadError`, if any.
    var anyError: Any? { get }

    /// A list of `PriorityStatusEntry` objects reporting the synchronization status for buckets within priorities.
    /// - Note: When buckets with different priorities are defined, this may contain entries before `hasSynced`
    /// and `lastSyncedAt` are set, indicating that a partial (but not complete) sync has completed.
    var priorityStatusEntries: [PriorityStatusEntry] { get }

    /// Retrieves the synchronization status for a specific priority.
    /// - Parameter priority: The priority for which the status is requested.
    /// - Returns: A `PriorityStatusEntry` representing the synchronization status for the given priority.
    func statusForPriority(_ priority: BucketPriority) -> PriorityStatusEntry
}

/// A protocol extending `SyncStatusData` to include flow-based updates for synchronization status.
public protocol SyncStatus: SyncStatusData, Sendable {
    /// Provides a flow of synchronization status updates.
    /// - Returns: An `AsyncStream` that emits updates whenever the synchronization status changes.
    func asFlow() -> AsyncStream<SyncStatusData>
}
