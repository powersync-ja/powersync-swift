public protocol PowerSyncTransactionProtocol {
    /// Execute a write query and return the number of affected rows
    func execute(
        sql: String,
        parameters: [Any]?
    ) async throws -> Int64
    
    /// Execute a read-only query and return a single optional result
    func getOptional<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType?
    
    /// Execute a read-only query and return all results
    func getAll<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> [RowType]
    
    /// Execute a read-only query and return a single result
    /// Throws if no result is found
    func get<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType
}
