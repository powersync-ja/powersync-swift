import Foundation

/// A collection of client-side changes.
public struct CrudBatch: Sendable {
    /// Indicates if there are additional Crud items in the queue which are not included in this batch
    public let hasMore: Bool

    /// List of client-side changes.
    public let crud: [CrudEntry]

    private let db: PowerSyncDatabaseProtocol

    internal init(hasMore: Bool, crud: [CrudEntry], db: PowerSyncDatabaseProtocol) {
        self.hasMore = hasMore
        self.crud = crud
        self.db = db
    }

    /// Call to remove the changes from the local queue, once successfully uploaded.
    ///
    /// `writeCheckpoint` is optional.
    public func complete(writeCheckpoint: String?) async throws {
        let lastId = crud.last!.clientId
        try await completeCrudItems(self.db, lastId)
    }

    /// Call to remove the changes from the local queue, once successfully uploaded.
    public func complete() async throws {
        try await self.complete(
            writeCheckpoint: nil
        )
    }
}

internal func completeCrudItems(_ db: any PowerSyncDatabaseProtocol, _ lastItemId: Int64, writeCheckpoint: String? = nil) async throws {
    return try await db.writeTransaction { tx in
        try tx.execute(sql: "DELETE FROM ps_crud WHERE id <= ?", parameters: [lastItemId])
        if writeCheckpoint != nil {
            let hasCrud = (try tx.getOptional(sql: "SELECT 1 FROM ps_crud", parameters: nil) { cursor in () }) != nil
            if !hasCrud {
                try tx.execute(sql: "UPDATE ps_buckets SET target_op = CAST(? AS INTEGER) WHERE name = '$local'", parameters: [writeCheckpoint])
                return
            }
        }
        try tx.execute(sql: "UPDATE ps_buckets SET target_op = 9223372036854775807 WHERE name = '$local'", parameters: nil)
    }
}
