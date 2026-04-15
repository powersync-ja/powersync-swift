import Foundation


/// A transaction of client-side changes.
public struct CrudTransaction: Sendable {
    /// Unique transaction id.
    ///
    /// If nil, this contains a list of changes recorded without an explicit transaction associated.
    public let transactionId: Int64

    /// List of client-side changes.
    public let crud: [CrudEntry]

    private let db: any PowerSyncDatabaseProtocol

    internal init(transactionId: Int64, crud: [CrudEntry], db: any PowerSyncDatabaseProtocol) {
        self.transactionId = transactionId
        self.crud = crud
        self.db = db
    }

    /// Call to remove the changes from the local queue, once successfully uploaded.
    ///
    /// `writeCheckpoint` is optional.
    public func complete(writeCheckpoint: String?) async throws {
        let id = self.crud.last!.clientId
        try await completeCrudItems(db, id, writeCheckpoint: writeCheckpoint)
    }

    /// Call to remove the changes from the local queue, once successfully uploaded.
    public func complete() async throws {
        try await self.complete(
            writeCheckpoint: nil
        )
    }
}

/// A sequence of crud transactions in a PowerSync database.
///
/// For details, see ``PowerSyncDatabaseProtocol/getCrudTransactions()``.
public struct CrudTransactions: AsyncSequence {
    public typealias Element = CrudTransaction
    public typealias AsyncIterator = CrudTransactionsIterator

    private let db: any PowerSyncDatabaseProtocol

    internal init(db: any PowerSyncDatabaseProtocol) {
        self.db = db
    }

    public func makeAsyncIterator() -> CrudTransactionsIterator {
        CrudTransactionsIterator(db: db)
    }
}

/// The iterator returned by ``CrudTransactions``.
public struct CrudTransactionsIterator: AsyncIteratorProtocol {
    public typealias Element = CrudTransaction

    private var lastItemId: Int64 = -1
    private let db: any PowerSyncDatabaseProtocol

    internal init(db: any PowerSyncDatabaseProtocol) {
        self.db = db
    }

    public mutating func next() async throws -> CrudTransaction? {
        // Note: We try to avoid filtering on tx_id here because there's no index on that column.
        // Starting at the first entry we want and then joining by rowid is more efficient. This is
        // sound because there can't be concurrent write transactions, so transaction ids are
        // increasing when we iterate over rowids.
        let query = """
WITH RECURSIVE crud_entries AS (
  SELECT id, tx_id, data FROM ps_crud WHERE id = (SELECT min(id) FROM ps_crud WHERE id > ?)
  UNION ALL
  SELECT ps_crud.id, ps_crud.tx_id, ps_crud.data FROM ps_crud
    INNER JOIN crud_entries ON crud_entries.id + 1 = rowid
  WHERE crud_entries.tx_id = ps_crud.tx_id
)
SELECT * FROM crud_entries;
"""

        let items = try await db.getAll(sql: query, parameters: [lastItemId], mapper: CrudEntry.fromCursor)
        if items.isEmpty {
            return nil
        }

        let txId = items.first!.transactionId
        let lastId = items.last!.clientId

        lastItemId = lastId
        return CrudTransaction(
            transactionId: txId!,
            crud: items,
            db: db
        )
    }
}
