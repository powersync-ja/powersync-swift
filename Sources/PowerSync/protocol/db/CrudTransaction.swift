import Foundation

/// A transaction of client-side changes.
public protocol CrudTransaction {
    /// Unique transaction id.
    ///
    /// If nil, this contains a list of changes recorded without an explicit transaction associated.
    var transactionId: Int64? { get }

    /// List of client-side changes.
    var crud: [any CrudEntry] { get }

    /// Call to remove the changes from the local queue, once successfully uploaded.
    ///
    /// `writeCheckpoint` is optional.
    func complete(writeCheckpoint: String?) async throws
}

public extension CrudTransaction {
    /// Call to remove the changes from the local queue, once successfully uploaded.
    ///
    /// `writeCheckpoint` is optional.
    func complete(writeCheckpoint: String? = nil) async throws {
        try await self.complete(
            writeCheckpoint: writeCheckpoint
        )
    }
}
