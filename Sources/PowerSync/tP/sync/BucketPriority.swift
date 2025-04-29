import Foundation

/// Represents the priority of a bucket, used for sorting and managing operations based on priority levels.
public struct BucketPriority: Comparable {
    /// The priority code associated with the bucket. Higher values indicate lower priority.
    public let priorityCode: Int32

    /// Initializes a new `BucketPriority` with the given priority code.
    /// - Parameter priorityCode: The priority code. Must be greater than or equal to 0.
    /// - Precondition: `priorityCode` must be >= 0.
    public init(_ priorityCode: Int32) {
        precondition(priorityCode >= 0, "priorityCode must be >= 0")
        self.priorityCode = priorityCode
    }

    /// Compares two `BucketPriority` instances to determine their order.
    /// - Parameters:
    ///   - lhs: The left-hand side `BucketPriority` instance.
    ///   - rhs: The right-hand side `BucketPriority` instance.
    /// - Returns: `true` if the left-hand side has a higher priority (lower `priorityCode`) than the right-hand side.
    /// - Note: Sorting is reversed, where a higher `priorityCode` means a lower priority.
    public static func < (lhs: BucketPriority, rhs: BucketPriority) -> Bool {
        return rhs.priorityCode < lhs.priorityCode
    }

    /// Represents the priority for a full synchronization operation, which has the lowest priority.
    public static let fullSyncPriority = BucketPriority(Int32.max)

    /// Represents the default priority for general operations.
    public static let defaultPriority = BucketPriority(3)
}
