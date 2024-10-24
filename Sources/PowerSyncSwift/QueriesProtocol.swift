import Foundation
import Combine

public protocol Queries {
    /// Execute a write query (INSERT, UPDATE, DELETE)
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
    func writeTransaction<R>(callback: @escaping (PowerSyncTransactionProtocol) async throws -> R) async throws -> R
    
    /// Execute a read transaction with the given callback
    func readTransaction<R>(callback: @escaping (PowerSyncTransactionProtocol) async throws -> R) async throws -> R
}
