import Foundation
import Combine
import PowerSyncKotlin

public protocol Queries {
    /// Execute a write query (INSERT, UPDATE, DELETE)
    /// Using `RETURNING *` will result in an error.
    func execute(sql: String, parameters: [Any]?) async throws -> Int64
    
    /// Execute a read-only (SELECT) query and return a single result.
    /// If there is no result, throws an IllegalArgumentException.
    /// See `getOptional` for queries where the result might be empty.
    func get<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType
    
    /// Execute a read-only (SELECT) query and return the results.
    func getAll<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> [RowType]
    
    /// Execute a read-only (SELECT) query and return a single optional result.
    func getOptional<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType?
    
    /// Execute a read-only (SELECT) query every time the source tables are modified
    /// and return the results as an array in a Publisher.
    func watch<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) -> AsyncStream<[RowType]>
    
    /// Execute a write transaction with the given callback
    func writeTransaction<R>(callback: @escaping (any PowerSyncTransaction) async throws -> R) async throws -> R

    /// Execute a read transaction with the given callback
    func readTransaction<R>(callback: @escaping (any PowerSyncTransaction) async throws -> R) async throws -> R
}

extension Queries {
    public func execute(_ sql: String) async throws -> Int64 {
        return try await execute(sql: sql, parameters: [])
    }

    public func get<RowType>(
        _ sql: String,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType {
        return try await get(sql: sql, parameters: [], mapper: mapper)
    }

    public func getAll<RowType>(
        _ sql: String,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> [RowType] {
        return try await getAll(sql: sql, parameters: [], mapper: mapper)
    }

    public func getOptional<RowType>(
        _ sql: String,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType? {
        return try await getOptional(sql: sql, parameters: [], mapper: mapper)
    }

    public func watch<RowType>(
        _ sql: String,
        mapper: @escaping (SqlCursor) -> RowType
    ) -> AsyncStream<[RowType]> {
        return watch(sql: sql, parameters: [], mapper: mapper)
    }
}
