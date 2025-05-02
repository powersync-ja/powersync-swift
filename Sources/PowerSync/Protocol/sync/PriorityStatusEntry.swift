import Foundation

/// Represents the status of a bucket priority, including synchronization details.
public struct PriorityStatusEntry {
    /// The priority of the bucket.
    public let priority: BucketPriority

    /// The date and time when the bucket was last synchronized.
    /// - Note: This value is optional and may be `nil` if the bucket has not been synchronized yet.
    public let lastSyncedAt: Date?

    /// Indicates whether the bucket has been successfully synchronized.
    /// - Note: This value is optional and may be `nil` if the synchronization status is unknown.
    public let hasSynced: Bool?
}
