import PowerSyncKotlin

struct KotlinCrudTransactions: CrudTransactions {
    typealias Element = KotlinCrudTransaction
    
    private let db: KotlinPowerSyncDatabase
    
    init(db: KotlinPowerSyncDatabase) {
        self.db = db
    }
    
    public func makeAsyncIterator() -> CrudTransactionIterator {
        let kotlinIterator = errorHandledCrudTransactions(db: self.db).makeAsyncIterator()
        return CrudTransactionIterator(inner: kotlinIterator)
    }
    
    struct CrudTransactionIterator: CrudTransactionsIterator {
        private var inner: PowerSyncKotlin.SkieSwiftFlowIterator<PowerSyncKotlin.PowerSyncResult>
        
        internal init(inner: PowerSyncKotlin.SkieSwiftFlowIterator<PowerSyncKotlin.PowerSyncResult>) {
            self.inner = inner
        }
        
        public mutating func next() async throws -> KotlinCrudTransaction? {
            if let innerTx = await self.inner.next() {
                if let success = innerTx as? PowerSyncResult.Success {
                    let tx = success.value as! PowerSyncKotlin.CrudTransaction
                    return try KotlinCrudTransaction(transaction: tx)
                } else if let failure = innerTx as? PowerSyncResult.Failure {
                    try throwPowerSyncException(exception: failure.exception)
                }
            
                fatalError("unreachable")
            } else {
                return nil
            }
        }
    }
}
