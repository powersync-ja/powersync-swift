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
    func execute(sql: String, parameters: [Any?]?) throws -> Int64 {
        try ctx.execute(
            sql: sql,
            parameters: mapParameters(parameters)
        )
    }

    func getOptional<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (any SqlCursor) throws -> RowType
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

    func getAll<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (any SqlCursor) throws -> RowType
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

    func get<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (any SqlCursor) throws -> RowType
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

class KotlinConnectionContext: KotlinConnectionContextProtocol {
    let ctx: PowerSyncKotlin.ConnectionContext

    init(ctx: PowerSyncKotlin.ConnectionContext) {
        self.ctx = ctx
    }
}

class KotlinTransactionContext: Transaction, KotlinConnectionContextProtocol {
    let ctx: PowerSyncKotlin.ConnectionContext

    init(ctx: PowerSyncKotlin.PowerSyncTransaction) {
        self.ctx = ctx
    }
}

// Allows nil values to be passed to the Kotlin [Any] params
func mapParameters(_ parameters: [Any?]?) -> [Any] {
    parameters?.map { item in
        item ?? NSNull()
    } ?? []
}
