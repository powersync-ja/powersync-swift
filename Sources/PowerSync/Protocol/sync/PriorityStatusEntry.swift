import Foundation

/// Represents the status of a bucket priority, including synchronization details.
public struct PriorityStatusEntry: Sendable, Decodable {
    /// The priority of the bucket.
    public let priority: BucketPriority

    /// The date and time when the bucket was last synchronized.
    /// - Note: This value is optional and may be `nil` if the bucket has not been synchronized yet.
    public let lastSyncedAt: Date?

    /// Indicates whether the bucket has been successfully synchronized.
    /// - Note: This value is optional and may be `nil` if the synchronization status is unknown.
    public let hasSynced: Bool?
    
    enum CodingKeys: String, CodingKey {
        case priority
        case lastSyncedAt = "last_synced_at"
        case hasSynced = "has_synced"
    }
    
    init(priority: BucketPriority, lastSyncedAt: Date?, hasSynced: Bool?) {
        self.priority = priority
        self.lastSyncedAt = lastSyncedAt
        self.hasSynced = hasSynced
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.priority = try container.decode(BucketPriority.self, forKey: .priority)
        self.lastSyncedAt = try container.decodeIfPresent(Int64.self, forKey: .lastSyncedAt).map(coreTimestampDate)
        self.hasSynced = try container.decodeIfPresent(Bool.self, forKey: .hasSynced)
    }
}
