import PowerSyncKotlin

/// Implements `CrudEntry` using the KotlinSDK
struct KotlinCrudEntry : CrudEntry {
    let entry: PowerSyncKotlin.CrudEntry
    let op: UpdateType
    
    init (
        entry: PowerSyncKotlin.CrudEntry
    ) throws {
        self.entry = entry
        self.op = try UpdateType.fromString(entry.op.name)
    }
    
    var id: String {
        entry.id
    }
    
    var clientId: Int64 {
        Int64(entry.clientId)
    }
    
    var table: String {
        entry.table
    }
    
    var transactionId: Int64? {
        entry.transactionId?.int64Value
    }
    
    var opData: [String : String?]? {
        /// Kotlin represents this as Map<String, String?>, but this is
        /// converted to [String: Any] by SKIEE
        entry.opData?.mapValues { $0 as? String }
    }
}
