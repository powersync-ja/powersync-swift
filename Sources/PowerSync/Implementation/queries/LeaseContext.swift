/// An implementation of ``ConnectionContext`` based on a raw ``SQLiteConnectionLease``.
final class ConnectionLeaseContext: ConnectionContext {
    private let lease: Mutex<SQLiteConnectionLease>

    init(lease: consuming SQLiteConnectionLease) {
        self.lease = Mutex(lease)
    }

    /// Maps any parameter array to typed SQLite values.
    private func mapParameters(_ parameters: [(any Sendable)?]?) throws -> [PowerSyncDataType?] {
        guard let parameters else {
            return []
        }

        return try parameters.map { parameter in
            if let convertible = parameter as? PowerSyncDataTypeConvertible {
                return convertible.psDataType
            } else if let parameter {
                return try PowerSyncDataType(from: parameter)
            } else {
                return nil
            }
        }
    }

    func execute(sql: String, parameters: [(any Sendable)?]?) throws -> Int64 {
        try lease.withLock { lease in
            return try lease.execute(sql: sql, parameters: mapParameters(parameters))
        }
    }

    func getOptional<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @escaping @Sendable (any SqlCursor) throws -> RowType) throws -> RowType? {
        try lease.withLock { lease in
            var stmt = try lease.iterate(sql: sql, parameters: mapParameters(parameters))
            return try stmt.stepWithCursor(callback: mapper)
        }
    }
    
    func getAll<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @escaping @Sendable (any SqlCursor) throws -> RowType) throws -> [RowType] {
        try lease.withLock { lease in
            var stmt = try lease.iterate(sql: sql, parameters: mapParameters(parameters))
            var result: [RowType] = []

            while let row = try stmt.stepWithCursor(callback: mapper) {
                result.append(row)
            }
            return result
        }
    }
    
    func get<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @escaping @Sendable (any SqlCursor) throws -> RowType) throws -> RowType {
        try lease.withLock { lease in
            var stmt = try lease.iterate(sql: sql, parameters: mapParameters(parameters))

            if let row = try stmt.stepWithCursor(callback: mapper) {
                return row
            } else {
                throw PowerSyncError.operationFailed(message: "Expected \(sql) to return a row, but got an empty result set.")
            }
        }
    }
}
