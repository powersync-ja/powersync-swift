import PowerSyncKotlin

/// Implements `CrudBatch` using the Kotlin SDK
struct KotlinCrudBatch: CrudBatch {
    let batch: PowerSyncKotlin.CrudBatch
    let crud: [CrudEntry]
    
    init(
        batch: PowerSyncKotlin.CrudBatch)
        throws
    {
        self.batch = batch
        self.crud = try batch.crud.map { try KotlinCrudEntry(
            entry: $0
        ) }
    }
    
    var hasMore: Bool {
        batch.hasMore
    }
    
    func complete(
        writeCheckpoint: String?
    ) async throws {
        _ = try await batch.complete.invoke(p1: writeCheckpoint)
    }
}
