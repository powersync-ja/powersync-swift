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

/// Removes the items from ps_crud
/// Sets the target op to a custom write checkpoint if provided,
/// otherwise sets the target to the PowerSyncDatabaseImpl.maxOpId -
/// which will allow setting the target via a checkpoint-request later
internal func completeCrudItems(_ db: any PowerSyncDatabaseProtocol, _ lastItemId: Int64, writeCheckpoint: String? = nil) async throws {
    return try await db.writeTransaction { tx in
        try tx.execute(sql: "DELETE FROM ps_crud WHERE id <= ?", parameters: [lastItemId])
        if writeCheckpoint != nil {
            let hasCrud = (try tx.getOptional(sql: "SELECT 1 FROM ps_crud", parameters: nil) { cursor in () }) != nil
            if !hasCrud {
                /// The fact that we set the target here, will be used to prevent creating a standard write checkpoint later
                try tx.execute(sql: "SELECT powersync_probe_local_target_op(?)", parameters: [writeCheckpoint])
                return
            }
        }
        try tx.execute(sql: "SELECT powersync_probe_local_target_op(?)", parameters: [PowerSyncDatabaseImpl.maxOpId])
    }
}
