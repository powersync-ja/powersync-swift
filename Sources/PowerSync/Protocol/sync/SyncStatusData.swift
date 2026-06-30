import Foundation

/// A protocol representing the synchronization status of a system, providing various indicators and error states.
public protocol SyncStatusData: Sendable {
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

    /// All sync streams currently being tracked in the database.
    ///
    /// This returns null when the database is currently being opened and we don't have reliable information about
    /// included streams yet.
    var syncStreams: [SyncStreamStatus]? { get }

    /// Status information for the given stream, if it's a stream that is currently tracked by the sync client.
    func forStream(stream: SyncStreamDescription) -> SyncStreamStatus?
}

/// A protocol extending `SyncStatusData` to include flow-based updates for synchronization status.
public protocol SyncStatus: SyncStatusData, Sendable {
    /// Provides a flow of synchronization status updates.
    /// - Returns: An `AsyncStream` that emits updates whenever the synchronization status changes.
    func asFlow() -> AsyncStream<SyncStatusData>
    
    /// An observable alternative to `asFlow()` that updates when the sync status changes.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @MainActor var observable: ObservableSyncStatus {get}
}

/// Current information about a ``SyncStreamSubscription``.
public struct SyncStreamStatus: Sendable {
    /// If the sync status is currently downloading, information about download progress related to this stream.
    public let progress: ProgressWithOperations?
    /// The ``SyncSubscriptionDescription`` providing information about the subscription.
    public let subscription: SyncSubscriptionDescription
    
    enum CodingKeys: CodingKey { case progress }
    
    init(subscription: SyncSubscriptionDescription, progress: ProgressWithOperations? = nil) {
        self.subscription = subscription
        self.progress = progress
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.progress = try container.decode(ProgressCounters.self, forKey: .progress)
        
        // Parse from same decoder (it's [flatten]ed in Rust)
        self.subscription = try SyncSubscriptionDescription(from: decoder)
    }
}

/// An observable version of ``SyncStatusData``.
///
/// In SwiftUI views and other reactive frameworks, this can be used as an alternative to ``SyncStatus/asFlow()`` to auto-update observers
/// when the PowerSync status changes.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@MainActor
@Observable()
public final class ObservableSyncStatus {
    internal var status: any SyncStatusData
    @ObservationIgnored
    private var observationTask: Task<(), Never>?

    internal init(status: any SyncStatusData) {
        self.status = status
    }

    deinit {
        self.observationTask?.cancel()
        self.observationTask = nil
    }
    
    internal func trackUpdates(from stream: BroadcastStream<any SyncStatusData>) {
        // Create iterator synchronously to make sure a listener is installed before we return, ensuring that
        // all updates are eventually dispatched to the task.
        let subscription = stream.subscribe()

        self.observationTask = Task { [weak self] in
            var iterator = subscription.makeAsyncIterator()
            while let snapshot = await iterator.next() {
                self?.status = snapshot
            }
        }
    }

    // This currently updates all listeners for every change, since status is the only observed field.
    // That matches asFlow(), in the future we might want to extract these values into separate fields and
    // only update them in trackUpdates when they've actually changed.

    public var connected: Bool { status.connected }
    public var connecting: Bool { status.connecting }
    public var downloading: Bool { status.downloading }
    public var downloadProgress: (any SyncDownloadProgress)? { status.downloadProgress }
    public var uploading: Bool { status.uploading }
    public var lastSyncedAt: Date? { status.lastSyncedAt }
    public var hasSynced: Bool? { status.hasSynced }
    public var uploadError: Any? { status.uploadError }
    public var downloadError: Any? { status.downloadError }
    public var anyError: Any? { status.anyError }
    public var priorityStatusEntries: [PriorityStatusEntry] { status.priorityStatusEntries }
    public var syncStreams: [SyncStreamStatus]? { status.syncStreams }
    public func statusForPriority(_ priority: BucketPriority) -> PriorityStatusEntry { status.statusForPriority(priority) }
    public func forStream(stream: any SyncStreamDescription) -> SyncStreamStatus? { status.forStream(stream: stream) }
}
