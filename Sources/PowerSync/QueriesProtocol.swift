import Combine
import Foundation
import PowerSyncKotlin

public let DEFAULT_WATCH_THROTTLE_MS = Int64(30)

public struct WatchOptions<RowType> {
    public var sql: String
    public var parameters: [Any]
    public var throttleMs: Int64
    public var mapper: (SqlCursor) throws -> RowType

    public init(sql: String, parameters: [Any]? = [], throttleMs: Int64? = DEFAULT_WATCH_THROTTLE_MS, mapper: @escaping (SqlCursor) throws -> RowType) {
        self.sql = sql
        self.parameters = parameters ?? [] // Default to empty array if nil
        self.throttleMs = throttleMs ?? DEFAULT_WATCH_THROTTLE_MS // Default to the constant if nil
        self.mapper = mapper
    }
}

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

    /// Execute a read-only (SELECT) query and return a single result.
    /// If there is no result, throws an IllegalArgumentException.
    /// See `getOptional` for queries where the result might be empty.
    func get<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType

    /// Execute a read-only (SELECT) query and return the results.
    func getAll<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> [RowType]

    /// Execute a read-only (SELECT) query and return the results.
    func getAll<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> [RowType]

    /// Execute a read-only (SELECT) query and return a single optional result.
    func getOptional<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType?

    /// Execute a read-only (SELECT) query and return a single optional result.
    func getOptional<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType?

    /// Execute a read-only (SELECT) query every time the source tables are modified
    /// and return the results as an array in a Publisher.
    func watch<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) -> RowType
    ) throws -> AsyncThrowingStream<[RowType], Error>

    /// Execute a read-only (SELECT) query every time the source tables are modified
    /// and return the results as an array in a Publisher.
    func watch<RowType>(
        sql: String,
        parameters: [Any]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) throws -> AsyncThrowingStream<[RowType], Error>

    func watch<RowType>(
        options: WatchOptions<RowType>
    ) throws -> AsyncThrowingStream<[RowType], Error>

    /// Execute a write transaction with the given callback
    func writeTransaction<R>(callback: @escaping (any PowerSyncTransaction) throws -> R) async throws -> R

    /// Execute a read transaction with the given callback
    func readTransaction<R>(callback: @escaping (any PowerSyncTransaction) throws -> R) async throws -> R
}

public extension Queries {
    func execute(_ sql: String) async throws -> Int64 {
        return try await execute(sql: sql, parameters: [])
    }

    func get<RowType>(
        _ sql: String,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType {
        return try await get(sql: sql, parameters: [], mapper: mapper)
    }

    func getAll<RowType>(
        _ sql: String,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> [RowType] {
        return try await getAll(sql: sql, parameters: [], mapper: mapper)
    }

    func getOptional<RowType>(
        _ sql: String,
        mapper: @escaping (SqlCursor) -> RowType
    ) async throws -> RowType? {
        return try await getOptional(sql: sql, parameters: [], mapper: mapper)
    }

    func watch<RowType>(
        _ sql: String,
        mapper: @escaping (SqlCursor) -> RowType
    ) throws -> AsyncThrowingStream<[RowType], Error> {
        return try watch(sql: sql, parameters: [], mapper: mapper)
    }
}
