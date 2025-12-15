import Foundation
import PowerSyncKotlin

/// Extension of the `ConnectionContext` protocol which allows mixin of common logic required for Kotlin adapters
protocol KotlinConnectionContextProtocol: ConnectionContext {
    /// Implementations should provide access to a Kotlin context.
    /// The protocol extension will use this to provide shared implementation.
    var ctx: PowerSyncKotlin.ConnectionContext { get }
}

/// Implements most of `ConnectionContext` using the `ctx` provided.
extension KotlinConnectionContextProtocol {
    func execute(sql: String, parameters: [Sendable?]?) throws -> Int64 {
        try ctx.execute(
            sql: sql,
            parameters: mapParameters(parameters)
        )
    }

    func getOptional<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (any SqlCursor) throws -> RowType
    ) throws -> RowType? {
        return try wrapQueryCursorTyped(
            mapper: mapper,
            executor: { wrappedMapper in
                try self.ctx.getOptional(
                    sql: sql,
                    parameters: mapParameters(parameters),
                    mapper: wrappedMapper
                )
            },
            resultType: RowType?.self
        )
    }

    func getAll<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (any SqlCursor) throws -> RowType
    ) throws -> [RowType] {
        return try wrapQueryCursorTyped(
            mapper: mapper,
            executor: { wrappedMapper in
                try self.ctx.getAll(
                    sql: sql,
                    parameters: mapParameters(parameters),
                    mapper: wrappedMapper
                )
            },
            resultType: [RowType].self
        )
    }

    func get<RowType: Sendable>(
        sql: String,
        parameters: [Sendable?]?,
        mapper: @Sendable @escaping (any SqlCursor) throws -> RowType
    ) throws -> RowType {
        return try wrapQueryCursorTyped(
            mapper: mapper,
            executor: { wrappedMapper in
                try self.ctx.get(
                    sql: sql,
                    parameters: mapParameters(parameters),
                    mapper: wrappedMapper
                )
            },
            resultType: RowType.self
        )
    }
}

final class KotlinConnectionContext: KotlinConnectionContextProtocol,
    // The Kotlin ConnectionContext is technically sendable, but we cannot annotate that
    @unchecked Sendable
{
    let ctx: PowerSyncKotlin.ConnectionContext

    init(ctx: PowerSyncKotlin.ConnectionContext) {
        self.ctx = ctx
    }
}

final class KotlinTransactionContext: Transaction, KotlinConnectionContextProtocol,
    // The Kotlin ConnectionContext is technically sendable, but we cannot annotate that
    @unchecked Sendable
{
    let ctx: PowerSyncKotlin.ConnectionContext

    init(ctx: PowerSyncKotlin.PowerSyncTransaction) {
        self.ctx = ctx
    }
}

// Allows nil values to be passed to the Kotlin [Any] params
func mapParameters(_ parameters: [Any?]?) -> [Any] {
    parameters?.map { item in
        switch item {
        case .none: NSNull()
        case let item as PowerSyncDataTypeConvertible:
            item.psDataType?.unwrap() ?? NSNull()
        default: item as Any
        }
    } ?? []
}
