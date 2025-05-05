/// Information about a progressing download.
/// 
/// This reports the ``totalOperations`` amount of operations to download, how many of them
/// have already been downloaded as ``downloadedOperations`` and finally a ``fraction`` indicating
/// relative progress.
/// 
/// To obtain a ``ProgressWithOperations`` instance, either use ``SyncStatusData/downloadProgress``
/// for global progress or ``SyncDownloadProgress/untilPriority(priority:)``.
public protocol ProgressWithOperations {
    /// How many operations need to be downloaded in total for the current download
    /// to complete.
    var totalOperations: Int32 { get }

    /// How many operations, out of ``totalOperations``, have already been downloaded.
    var downloadedOperations: Int32 { get }
}

public extension ProgressWithOperations {
    /// The relative amount of ``totalOperations`` to items in ``downloadedOperations``, as a
    /// number between `0.0` and `1.0` (inclusive).
    /// 
    /// When this number reaches `1.0`, all changes have been received from the sync service.
    /// Actually applying these changes happens before the ``SyncStatusData/downloadProgress``
    /// field is cleared though, so progress can stay at `1.0` for a short while before completing.
    var fraction: Float {
        if (self.totalOperations == 0) {
            return 0.0
        }

        return Float.init(self.downloadedOperations) / Float.init(self.totalOperations)
    }
}

/// Provides realtime progress on how PowerSync is downloading rows.
/// 
/// This type reports progress by extending ``ProgressWithOperations``, meaning that the
/// ``ProgressWithOperations/totalOperations``, ``ProgressWithOperations/downloadedOperations``
/// and ``ProgressWithOperations/fraction`` properties are available on this instance.
/// Additionally, it's possible to obtain progress towards a specific priority only (instead
/// of tracking progress for the entire download) by using ``untilPriority(priority:)``.
/// 
/// The reported progress always reflects the status towards the end of a sync iteration (after
/// which a consistent snapshot of all buckets is available locally).
/// 
/// In rare cases (in particular, when a [compacting](https://docs.powersync.com/usage/lifecycle-maintenance/compacting-buckets)
/// operation takes place between syncs), it's possible for the returned numbers to be slightly
/// inaccurate. For this reason, ``SyncDownloadProgress`` should be seen as an approximation of progress.
/// The information returned is good enough to build progress bars, but not exaxt enough to track
/// individual download counts.
/// 
/// Also note that data is downloaded in bulk, which means that individual counters are unlikely
/// to be updated one-by-one.
public protocol SyncDownloadProgress: ProgressWithOperations {
    /// Returns download progress towardss all data up until the specified `priority`
    /// being received.
    /// 
    /// The returned ``ProgressWithOperations`` instance tracks the target amount of operations that
    /// need to be downloaded in total and how many of them have already been received.
    func untilPriority(priority: BucketPriority) -> ProgressWithOperations
}
