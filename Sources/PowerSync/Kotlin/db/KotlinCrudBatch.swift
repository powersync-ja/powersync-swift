import PowerSyncKotlin

struct KotlinCrudBatch: CrudBatch {
    let base: PowerSyncKotlin.CrudBatch
    let crud: [CrudEntry]
    
    init (_ base: PowerSyncKotlin.CrudBatch) throws {
        self.base = base
        self.crud = try base.crud.map { try KotlinCrudEntry($0) }
    }
    
    var hasMore: Bool {
        base.hasMore
    }
    
    func complete(writeCheckpoint: String?) async throws {
        _ = try await base.complete.invoke(p1: writeCheckpoint)
    }
}
