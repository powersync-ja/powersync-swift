import Foundation
import PowerSync
import StructuredQueries

/// The Structured Queries library is dialect agnostic.
/// For our purposes, we can use "?" for placeholders.
public extension QueryFragment {
    func prepareSqlite() -> (sql: String, bindings: [QueryBinding]) {
        prepare { _ in "?" }
    }
}

@usableFromInline
final class QueryValueCursor<QueryValue: QueryRepresentable> {
    public typealias Element = QueryValue.QueryOutput
    @usableFromInline
    let powerSync: PowerSyncDatabaseProtocol

    @usableFromInline
    let query: QueryFragment

    @usableFromInline
    init(powerSync: PowerSyncDatabaseProtocol, query: QueryFragment) throws {
        self.powerSync = powerSync
        self.query = query
    }

    /// Performs a `PowerSyncDatabaseProtocol.getAll` to execute a SELECT query.
    /// A decoder users the provided `SqlCursor` to map the columns to the Structured Table type.
    @inlinable
    public func elements() async throws -> [Element] {
        let preparedQuery = query.prepareSqlite()
        return try await powerSync.getAll(
            sql: preparedQuery.sql,
            parameters: preparedQuery.bindings.map { try $0.powerSyncValue }
        ) { psCursor in

            var decoder = PowerSyncQueryDecoder(cursor: psCursor)
            return try QueryValue(decoder: &decoder).queryOutput
        }
    }
}

/// The bindings provided by `prepare` seem to be wrapped in a Swift class
/// which causes binding to fail. This converts values to be usable by the Kotlin SDK.
extension QueryBinding {
    @inlinable
    var powerSyncValue: Sendable? {
        get throws {
            switch self {
            case let .blob(blob):
                return blob
            case let .date(date):
                let formatter = ISO8601DateFormatter()
                return formatter.string(from: date)
            case let .double(double):
                return double
            case let .int(int):
                return int
            case .null:
                return nil
            case let .text(text):
                return text
            case let .uuid(uuid):
                return uuid.uuidString
            case let .invalid(error):
                throw error
            }
        }
    }
}
