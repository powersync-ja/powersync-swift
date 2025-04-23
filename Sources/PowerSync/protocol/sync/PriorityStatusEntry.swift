import Foundation

public struct PriorityStatusEntry {
    public let priority: BucketPriority
    public let lastSyncedAt: Date?
    public let hasSynced: Bool?
}
