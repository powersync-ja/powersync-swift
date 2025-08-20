import Foundation
import PowerSync
import StructuredQueries

@usableFromInline
struct PowerSyncQueryDecoder: QueryDecoder {
    /// The structured queries library will decode the typed struct's columns in
    /// the same order which it compiled the SELECT statement's column list.
    /// The library will call the correct typed `decode` method, we just need to keep
    /// track of which column index we're on.
    @usableFromInline
    var currentIndex: Int = 0

    /// The PowerSync `SqlCursor` provided in the `mapper` closure.
    @usableFromInline
    var cursor: SqlCursor

    @usableFromInline
    init(cursor: SqlCursor) {
        self.cursor = cursor
    }

    /// Decodes a single tuple of the given type starting from the current column.
    ///
    /// - Parameter columnTypes: The types to decode as.
    /// - Returns: A tuple of the requested types.
    @inlinable
    @inline(__always)
    public mutating func decodeColumns<each T: QueryRepresentable>(
        _: (repeat each T).Type
    ) throws -> (repeat (each T).QueryOutput) {
        try (repeat (each T)(decoder: &self).queryOutput)
    }

    @inlinable
    mutating func decode(_: [UInt8].Type) throws -> [UInt8]? {
        defer { currentIndex += 1 }
        // TODO: blob support
        return nil
    }

    @inlinable
    mutating func decode(_: Bool.Type) throws -> Bool? {
        try decode(Int64.self).map { $0 != 0 }
    }

    @inlinable
    mutating func decode(_: Date.Type) throws -> Date? {
        try decode(String.self).map {
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: $0) else {
                throw InvalidDate()
            }
            return date
        }
    }

    @inlinable
    mutating func decode(_: Double.Type) throws -> Double? {
        defer { currentIndex += 1 }
        return cursor.getDoubleOptional(index: currentIndex)
    }

    @inlinable
    mutating func decode(_: Int.Type) throws -> Int? {
        try decode(Int64.self).map(Int.init)
    }

    @inlinable
    mutating func decode(_: Int64.Type) throws -> Int64? {
        defer { currentIndex += 1 }
        return cursor.getInt64Optional(index: currentIndex)
    }

    @inlinable
    mutating func decode(_: String.Type) throws -> String? {
        defer { currentIndex += 1 }
        return cursor.getStringOptional(index: currentIndex)
    }

    @inlinable
    mutating func decode(_: UUID.Type) throws -> UUID? {
        guard let uuidString = try decode(String.self) else { return nil }
        guard let uuid = UUID(uuidString: uuidString) else { throw InvalidUUID() }
        return uuid
    }
}

@usableFromInline
struct InvalidUUID: Error {
    @usableFromInline
    init() {}
}

@usableFromInline
struct InvalidDate: Error {
    @usableFromInline
    init() {}
}
