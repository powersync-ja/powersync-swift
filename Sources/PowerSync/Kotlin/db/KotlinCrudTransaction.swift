import PowerSyncKotlin

struct KotlinCrudTransaction: CrudTransaction {
    let transaction: PowerSyncKotlin.CrudTransaction
    let crud: [CrudEntry]
    
    init(transaction: PowerSyncKotlin.CrudTransaction) throws {
        self.transaction = transaction
        self.crud = try transaction.crud.map { try KotlinCrudEntry(
            entry: $0
        ) }
    }
    
    var transactionId: Int64? {
        transaction.transactionId?.int64Value
    }
    
    func complete(writeCheckpoint: String?) async throws {
        _ = try await transaction.complete.invoke(p1: writeCheckpoint)
    }
}
