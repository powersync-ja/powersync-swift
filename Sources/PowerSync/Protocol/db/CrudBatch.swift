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
    public func complete(writeCheckpoint: String? = nil) async throws {
        let lastId = crud.last!.clientId
        try await completeCrudItems(self.db, lastId, writeCheckpoint: writeCheckpoint)
    }
}

/// Removes uploaded CRUD items and updates the local target marker.
///
/// If a custom write checkpoint is supplied and no CRUD items remain, that checkpoint becomes
/// the target. Otherwise, the target is reset to ``PowerSyncDatabaseImpl/maxOpId`` so the sync
/// client can create a standard write checkpoint later.
internal func completeCrudItems(_ db: any PowerSyncDatabaseProtocol, _ lastItemId: Int64, writeCheckpoint: String? = nil) async throws {
    return try await db.writeTransaction { tx in
        try tx.execute(sql: "DELETE FROM ps_crud WHERE id <= ?", parameters: [lastItemId])
        if writeCheckpoint != nil {
            let hasCrud = (try tx.getOptional(sql: "SELECT 1 FROM ps_crud", parameters: nil) { cursor in () }) != nil
            if !hasCrud {
                // Setting a concrete target here prevents the sync client from replacing it
                // with a standard write checkpoint after upload completion.
                try tx.execute(sql: "SELECT powersync_probe_local_target_op(?)", parameters: [writeCheckpoint])
                return
            }
        }
        try tx.execute(sql: "SELECT powersync_probe_local_target_op(?)", parameters: [PowerSyncDatabaseImpl.maxOpId])
    }
}
