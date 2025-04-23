import PowerSyncKotlin

struct KotlinCrudTransaction: CrudTransaction {
    let base: PowerSyncKotlin.CrudTransaction
    let crud: [CrudEntry]
    
    init (_ base: PowerSyncKotlin.CrudTransaction) throws {
        self.base = base
        self.crud = try base.crud.map { try KotlinCrudEntry($0) }
    }
    
    var transactionId: Int32? {
        base.transactionId?.int32Value
    }
    
    func complete(writeCheckpoint: String?) async throws {
        _ = try await base.complete.invoke(p1: writeCheckpoint)
    }
}
