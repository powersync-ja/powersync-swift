import Foundation

public struct BucketPriority: Comparable {
    public let priorityCode: Int32

    public init(_ priorityCode: Int32) {
        precondition(priorityCode >= 0, "priorityCode must be >= 0")
        self.priorityCode = priorityCode
    }

    // Reverse sorting: higher `priorityCode` means lower priority
    public static func < (lhs: BucketPriority, rhs: BucketPriority) -> Bool {
        return rhs.priorityCode < lhs.priorityCode
    }

    // MARK: - Predefined priorities
    public static let fullSyncPriority = BucketPriority(Int32.max)
    public static let defaultPriority = BucketPriority(3)
}
