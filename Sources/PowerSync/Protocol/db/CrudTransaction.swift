import Foundation

/// A transaction of client-side changes.
public protocol CrudTransaction: Sendable {
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
    func complete() async throws {
        try await self.complete(
            writeCheckpoint: nil
        )
    }
}

/// A sequence of crud transactions in a PowerSync database.
///
/// For details, see ``PowerSyncDatabaseProtocol/getCrudTransactions()``.
public protocol CrudTransactions: AsyncSequence where Element: CrudTransaction, AsyncIterator: CrudTransactionsIterator {}

/// The iterator returned by ``CrudTransactions``.
public protocol CrudTransactionsIterator: AsyncIteratorProtocol where Element: CrudTransaction {}
