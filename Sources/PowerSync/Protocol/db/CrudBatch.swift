import Foundation

/// A transaction of client-side changes.
public protocol CrudBatch: Sendable {
    /// Indicates if there are additional Crud items in the queue which are not included in this batch
    var hasMore: Bool { get }

    /// List of client-side changes.
    var crud: [any CrudEntry] { get }

    /// Call to remove the changes from the local queue, once successfully uploaded.
    ///
    /// `writeCheckpoint` is optional.
    func complete(writeCheckpoint: String?) async throws
}

public extension CrudBatch {
    /// Call to remove the changes from the local queue, once successfully uploaded.
    func complete() async throws {
        try await self.complete(
            writeCheckpoint: nil
        )
    }
}
