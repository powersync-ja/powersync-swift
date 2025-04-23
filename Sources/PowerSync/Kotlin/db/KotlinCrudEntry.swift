import PowerSyncKotlin

struct KotlinCrudEntry : CrudEntry {
    let base: PowerSyncKotlin.CrudEntry
    let op: UpdateType
    
    init (_ base: PowerSyncKotlin.CrudEntry) throws {
        self.base = base
        self.op = try UpdateType.fromString(base.op.name)
    }
    
    var id: String {
        base.id
    }
    
    var clientId: Int32 {
        base.clientId
    }
    
    var table: String {
        base.table
    }
    
    var transactionId: Int32? {
        base.transactionId?.int32Value
    }
    
    var opData: [String : String?]? {
        /// Kotlin represents this as Map<String, String?>, but this is
        /// converted to [String: Any] by SKIEE
        base.opData?.mapValues { $0 as? String }
    }
}
