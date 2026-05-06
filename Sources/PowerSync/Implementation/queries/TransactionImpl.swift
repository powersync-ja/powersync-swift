struct TransactionImpl: Transaction {
    let inner: ConnectionContext
    
    func execute(sql: String, parameters: [(any Sendable)?]?) throws -> Int64 {
        return try self.inner.execute(sql: sql, parameters: parameters)
    }
    
    func getOptional<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @escaping @Sendable (any SqlCursor) throws -> RowType) throws -> RowType? {
        return try self.inner.getOptional(sql: sql, parameters: parameters, mapper: mapper)
    }
    
    func getAll<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @escaping @Sendable (any SqlCursor) throws -> RowType) throws -> [RowType] {
        return try self.inner.getAll(sql: sql, parameters: parameters, mapper: mapper)
    }
    
    func get<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @escaping @Sendable (any SqlCursor) throws -> RowType) throws -> RowType {
        return try self.inner.get(sql: sql, parameters: parameters, mapper: mapper)
    }
    
    static func run<R>(conn: any ConnectionContext, callback: @Sendable (any Transaction) throws -> R) throws -> R {
        let _ = try conn.execute(sql: "BEGIN IMMEDIATE", parameters: nil)
        
        do {
            let result = try callback(TransactionImpl(inner: conn))
            let _ = try conn.execute(sql: "COMMIT", parameters: nil)
            return result
        } catch {
            do {
                let _ = try conn.execute(sql: "ROLLBACK", parameters: nil)
            } catch {
                // Failed rollback, probably an INSERT OR ROLLBACK statement that rolled the transaction back already. Ignore.
            }
            
            throw error
        }
    }
}
