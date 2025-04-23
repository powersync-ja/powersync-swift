import Foundation

public protocol SyncStatusData {
    var connected: Bool { get }
    var connecting: Bool { get }
    var downloading: Bool { get }
    var uploading: Bool { get }
    var lastSyncedAt: Date? { get }
    var hasSynced: Bool? { get }
    var uploadError: Any? { get }
    var downloadError: Any? { get }
    var anyError: Any? { get }
    var priorityStatusEntries: [PriorityStatusEntry] { get }

    func statusForPriority(_ priority: BucketPriority) -> PriorityStatusEntry
}


public protocol SyncStatus : SyncStatusData {
    func asFlow() -> AsyncStream<SyncStatusData>
}

