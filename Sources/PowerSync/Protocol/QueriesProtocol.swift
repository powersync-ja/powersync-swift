import Combine
import Foundation

public let DEFAULT_WATCH_THROTTLE: TimeInterval = 0.03 // 30ms

public struct WatchOptions<RowType>: Sendable {
    public var sql: String
    public var parameters: [Sendable?]
    public var throttle: TimeInterval
    public var mapper: @Sendable (SqlCursor) throws -> RowType

    public init(
        sql: String, parameters: [Sendable?]? = [],
        throttle: TimeInterval? = DEFAULT_WATCH_THROTTLE,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) {
        self.sql = sql
        self.parameters = parameters ?? []
        self.throttle = throttle ?? DEFAULT_WATCH_THROTTLE
        self.mapper = mapper
    }
}

public protocol Queries {
    /// Execute a write query (INSERT, UPDATE, DELETE)
    /// Using `RETURNING *` will result in an error.
    @discardableResult
    func execute(sql: String, parameters: [Sendable?]?) async throws -> Int64

    /// Execute a read-only (SELECT) query and return a single result.
    /// If there is no result, throws an IllegalArgumentException.
    /// See `getOptional` for queries where the result might be empty.
    func get<RowType>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType

    /// Execute a read-only (SELECT) query and return the results.
    func getAll<RowType>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) async throws -> [RowType]

    /// Execute a read-only (SELECT) query and return a single optional result.
    func getOptional<RowType>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType?

    /// Execute a read-only (SELECT) query every time the source tables are modified
    /// and return the results as an array in a Publisher.
    func watch<RowType>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) throws -> AsyncThrowingStream<[RowType], Error>

    func watch<RowType>(
        options: WatchOptions<RowType>
    ) throws -> AsyncThrowingStream<[RowType], Error>

    /// Takes a global lock, without starting a transaction.
    ///
    /// In most cases, [writeTransaction] should be used instead.
    func writeLock<R>(
        callback: @Sendable @escaping (any ConnectionContext) throws -> R
    ) async throws -> R

    /// Takes a read lock, without starting a transaction.
    ///
    /// The lock only applies to a single connection, and multiple
    /// connections may hold read locks at the same time.
    func readLock<R>(
        callback: @Sendable @escaping (any ConnectionContext) throws -> R
    ) async throws -> R

    /// Execute a write transaction with the given callback
    func writeTransaction<R>(
        callback: @Sendable @escaping (any Transaction) throws -> R
    ) async throws -> R

    /// Execute a read transaction with the given callback
    func readTransaction<R>(
        callback: @Sendable @escaping (any Transaction) throws -> R
    ) async throws -> R
}

public extension Queries {
    @discardableResult
    func execute(_ sql: String) async throws -> Int64 {
        return try await execute(sql: sql, parameters: [])
    }

    func get<RowType>(
        _ sql: String,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType {
        return try await get(sql: sql, parameters: [], mapper: mapper)
    }

    func getAll<RowType>(
        _ sql: String,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) async throws -> [RowType] {
        return try await getAll(sql: sql, parameters: [], mapper: mapper)
    }

    func getOptional<RowType>(
        _ sql: String,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) async throws -> RowType? {
        return try await getOptional(sql: sql, parameters: [], mapper: mapper)
    }

    func watch<RowType>(
        _ sql: String,
        mapper: @Sendable @escaping (SqlCursor) throws -> RowType
    ) throws -> AsyncThrowingStream<[RowType], Error> {
        return try watch(sql: sql, parameters: [Sendable?](), mapper: mapper)
    }
}
