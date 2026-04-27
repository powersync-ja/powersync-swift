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
            try lease.withIterator(sql: sql, parameters: mapParameters(parameters)) { rows in
                return try rows.next(callback: mapper)
            }
        }
    }
    
    func getAll<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @escaping @Sendable (any SqlCursor) throws -> RowType) throws -> [RowType] {
        try lease.withLock { lease in
            try lease.withIterator(sql: sql, parameters: mapParameters(parameters)) { rows in
                var result: [RowType] = []
                while let row = try rows.next(callback: mapper) {
                    result.append(row)
                }
                return result
            }
        }
    }
    
    func get<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @escaping @Sendable (any SqlCursor) throws -> RowType) throws -> RowType {
        try lease.withLock { lease in
            try lease.withIterator(sql: sql, parameters: mapParameters(parameters)) { rows in
                guard let cursor = try rows.next(callback: mapper) else {
                    throw PowerSyncError.operationFailed(message: "Expected \(sql) to return a row, but got an empty result set.")
                }
                return cursor
            }
        }
    }
}
