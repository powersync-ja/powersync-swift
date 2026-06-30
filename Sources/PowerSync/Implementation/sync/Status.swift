import Foundation

/// The internal struct backing all sync status fields.
/// 
/// The core extension drives most of the sync status through ``CoreDownloadSyncStatus``.
/// Additionally, we track upload status and Swift errors.
struct MutableSyncStatus: ~Copyable {
    var core: CoreDownloadSyncStatus = CoreDownloadSyncStatus()
    var uploading: Bool = false
    var internalDownloadError: (any Error & Sendable)?
    var internalUploadError: (any Error & Sendable)?
}

/// An immutable snapshot of ``MutableSyncStatus``.
fileprivate struct SyncStatusDataImpl: SyncStatusData {
    let core: CoreDownloadSyncStatus
    let downloadProgress: (any SyncDownloadProgress)?
    let uploading: Bool

    let internalDownloadError: (any Error & Sendable)?
    let internalUploadError: (any Error & Sendable)?

    init(status: borrowing MutableSyncStatus) {
        self.core = status.core
        self.uploading = status.uploading
        self.internalUploadError = status.internalUploadError
        self.internalDownloadError = status.internalDownloadError
        
        if let downloading = core.downloading {
            self.downloadProgress = IndexedCoreDownloadProgress(inner: downloading)
        } else {
            self.downloadProgress = nil
        }
    }

    var connected: Bool {
        core.connected
    }

    var connecting: Bool {
        core.connecting
    }

    var downloading: Bool {
        core.downloading != nil
    }

    var lastSyncedAt: Date? {
        let completeSyncStatus = core.priorityStatus.first { $0.priority == .fullSyncPriority }
        return completeSyncStatus?.lastSyncedAt
    }

    var hasSynced: Bool? {
        lastSyncedAt != nil
    }
    
    var downloadError: Any? {
        internalDownloadError
    }

    var uploadError: Any? {
        internalUploadError
    }

    var anyError: Any? {
        downloadError ?? uploadError
    }

    var priorityStatusEntries: [PriorityStatusEntry] {
        core.priorityStatus
    }

    var syncStreams: [SyncStreamStatus]? {
        if downloadProgress != nil {
            return core.streams
        } else {
            // core.streams includes progress information, we need to hide that since we're not currently
            // downloading anything.
            return core.streams.map { stream in SyncStreamStatus.init(subscription: stream.subscription) }
        }
    }

    func statusForPriority(_ priority: BucketPriority) -> PriorityStatusEntry {
        for known in priorityStatusEntries {
            // Lower-priority buckets are synced after higher-priority buckets, and since priorityStatusEntries
            // is sorted, we look for the first entry that doesn't have a higher priority.
            if known.priority <= priority {
                return known
            }
        }
        
        // Fallback, report status for complete sync (which necessarily includes all priorities)
        return PriorityStatusEntry(priority: priority, lastSyncedAt: lastSyncedAt, hasSynced: hasSynced)
    }

    func forStream(stream: any SyncStreamDescription) -> SyncStreamStatus? {
        guard let streams = syncStreams else {
            return nil
        }

        for found in streams {
            if found.subscription.name == stream.name && found.subscription.parameters == stream.parameters {
                return found
            }
        }
        
        return nil
    }
}

fileprivate struct SyncStatusContainer: ~Copyable {
    var inner: MutableSyncStatus
    var snapshot: SyncStatusDataImpl

    init(inner: consuming MutableSyncStatus) {
        self.snapshot = SyncStatusDataImpl(status: inner)
        self.inner = inner
    }
}

final class SwiftSyncStatus: SyncStatus {
    private let current: Mutex<SyncStatusContainer>
    private let listeners: BroadcastStream<any SyncStatusData> = BroadcastStream()
    @MainActor private var _observable: Any? // ObservableSyncStatus, only available on newer platform versions

    init() {
        self.current = Mutex(SyncStatusContainer(inner: MutableSyncStatus()))
    }

    private func readStatus<T>(status: (borrowing SyncStatusDataImpl) -> T) -> T {
        return self.current.withLock { status($0.snapshot) }
    }
    
    private func copySnapshot() -> any SyncStatusData {
        self.current.withLock { status in status.snapshot }
    }

    internal func mutateStatus(update: (_ status: inout MutableSyncStatus) -> Void) {
        maybeMutateStatus(shouldUpdate: { _ in true }, apply: update)
    }
    
    internal func maybeMutateStatus(
        shouldUpdate: (_ status: borrowing MutableSyncStatus) -> Bool,
        apply: (_ status: inout MutableSyncStatus) -> Void
    ) {
        let didUpdate = self.current.withLock {
            if shouldUpdate($0.inner) {
                apply(&$0.inner)
                $0.snapshot = SyncStatusDataImpl(status: $0.inner)
                return true
            } else {
                return false
            }
        }
        
        if didUpdate {
            self.listeners.dispatch(event: copySnapshot())
        }
    }

    func asFlow() -> AsyncStream<any SyncStatusData> {
        self.listeners.subscribe(addInitial: copySnapshot())
    }
    
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @MainActor var observable: ObservableSyncStatus {
        if let observable = _observable as? ObservableSyncStatus {
            return observable
        }
        
        let observable = ObservableSyncStatus(status: copySnapshot())
        observable.trackUpdates(from: self.listeners)
        _observable = observable
        return observable
    }

    /// Waits for the first sync status matching a predicate.
    func waitFor(_ predicate: (borrowing SwiftSyncStatus) -> Bool) async {
        for await _ in self.asFlow() {
            if predicate(self) {
                return
            }
        }
    }

    var connected: Bool {
        self.readStatus { current in current.connected }
    }

    var connecting: Bool {
        self.readStatus { current in current.connecting }
    }

    var downloading: Bool {
        self.readStatus { current in current.downloading }
    }

    var downloadProgress: (any SyncDownloadProgress)? {
        self.readStatus { current in current.downloadProgress }
    }
    
    var uploading: Bool {
        self.readStatus { current in current.uploading }
    }

    var lastSyncedAt: Date? {
        self.readStatus { current in current.lastSyncedAt }
    }

    var hasSynced: Bool? {
        self.readStatus { current in current.hasSynced }
    }

    var downloadError: Any? {
        self.readStatus { current in current.downloadError }
    }

    var uploadError: Any? {
        self.readStatus { current in current.uploadError }
    }

    var anyError: Any? {
        self.readStatus { current in current.anyError }
    }

    var priorityStatusEntries: [PriorityStatusEntry] {
        self.readStatus { current in current.priorityStatusEntries }
    }

    var syncStreams: [SyncStreamStatus]? {
        self.readStatus { current in current.syncStreams }
    }

    func statusForPriority(_ priority: BucketPriority) -> PriorityStatusEntry {
        self.readStatus { current in current.statusForPriority(priority) }
    }

    func forStream(stream: any SyncStreamDescription) -> SyncStreamStatus? {
        self.readStatus { current in current.forStream(stream: stream) }
    }
}

struct IndexedCoreDownloadProgress: SyncDownloadProgress {
    private let inner: CoreSyncDownloadProgress
    
    let totalOperations: Int32
    let downloadedOperations: Int32
    
    init(inner: CoreSyncDownloadProgress) {
        self.inner = inner
        let (total, downloaded) = inner.buckets.values.reduce((0, 0), Self.addProgress)
        self.totalOperations = total
        self.downloadedOperations = downloaded
    }
    
    func untilPriority(priority: BucketPriority) -> any ProgressWithOperations {
        let (total, downloaded) = inner.buckets.values.filter{ bkt in bkt.priority >= priority }.reduce((0, 0), Self.addProgress)
        return ProgressCounters(total: total, downloaded: downloaded)
    }
    
    private static func addProgress(prev: (Int32, Int32), entry: BucketProgress) -> (Int32, Int32) {
        let downloaded = Int32(entry.sinceLast)
        let total = Int32(entry.targetCount - entry.atLast)
        return (prev.0 + total, prev.1 + downloaded)
    }
}
