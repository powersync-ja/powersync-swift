import Foundation
import PowerSync
import SwiftData

private protocol OptionalTypeMarker {
    static var wrappedType: Any.Type { get }
}

extension Optional: OptionalTypeMarker {
    static var wrappedType: Any.Type { Wrapped.self }
}

/// Converts values between their Swift types (as stored in ``PowerSyncSnapshot``) and the
/// SQLite representations PowerSync uses (`text`/`integer`/`real` columns).
///
/// Representation choices (PowerSync has no blob column type and `SqlCursor` exposes no
/// blob getter, so binary types ride on `text`):
/// - `Date` -> `real` (seconds since 1970)
/// - `UUID` -> `text` (uuidString)
/// - `Data` -> `text` (base64)
/// - `RawRepresentable` enums -> their raw value's column type
/// - other `Codable` values -> `text` (JSON, ISO 8601 dates, sorted keys)
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
enum ValueCoercion {
    /// The column type backing a raw-representable enum.
    enum RawKind: Sendable {
        case string
        case int
        case int64
        case int32
        case double
    }

    /// How a model property's value type is stored in its PowerSync column.
    enum Kind: Sendable {
        case string
        case bool
        case int
        case int64
        case int32
        case double
        case float
        case date
        case uuid
        case data
        case rawRepresentable(type: any (RawRepresentable & Decodable & Encodable & Sendable).Type, rawKind: RawKind)
        case codable(type: any (Decodable & Encodable & Sendable).Type)
    }

    /// `Optional<String>.self` becomes `String.self`; non-optional metatypes pass through.
    /// Unwrapping before dispatching on the type is required for optional values to cast.
    static func unwrapOptionalMetatype(_ type: Any.Type) -> Any.Type {
        (type as? OptionalTypeMarker.Type)?.wrappedType ?? type
    }

    /// `Optional(Optional("x"))` becomes `"x"`; `Optional<T>.none` becomes `nil`.
    static func flattenOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        guard let child = mirror.children.first else {
            return nil
        }
        return flattenOptional(child.value)
    }

    /// Converts an untyped value (such as a schema default) into a snapshot value of the
    /// property's kind. Returns `nil` when the value does not match the kind.
    static func snapshotValue(from value: Any, kind: Kind) -> (any DataStoreSnapshotValue)? {
        func openAny(_ type: any (Decodable & Encodable & Sendable).Type) -> (any DataStoreSnapshotValue)? {
            func go<V: Decodable & Encodable & Sendable>(_: V.Type) -> (any DataStoreSnapshotValue)? {
                (value as? V).map { $0 as any DataStoreSnapshotValue }
            }
            return go(type)
        }
        switch kind {
        case .string: return value as? String
        case .bool: return value as? Bool
        case .int: return value as? Int
        case .int64: return value as? Int64
        case .int32: return value as? Int32
        case .double: return value as? Double
        case .float: return value as? Float
        case .date: return value as? Date
        case .uuid: return value as? UUID
        case .data: return value as? Data
        case let .rawRepresentable(type, _): return openAny(type)
        case let .codable(type): return openAny(type)
        }
    }

    /// Whether two values are equal under the column representation for `kind`.
    /// Used to diff incoming PowerSync rows against registered model state.
    static func representationsEqual(_ lhs: Any?, _ rhs: Any?, kind: Kind) -> Bool {
        let left = try? parameter(from: lhs, kind: kind, entity: "", property: "")
        let right = try? parameter(from: rhs, kind: kind, entity: "", property: "")
        switch (left ?? nil, right ?? nil) {
        case (nil, nil):
            return true
        case let (lhs as String, rhs as String):
            return lhs == rhs
        case let (lhs as Int64, rhs as Int64):
            return lhs == rhs
        case let (lhs as Double, rhs as Double):
            return lhs == rhs
        default:
            return false
        }
    }

    static func kind(of valueType: Any.Type, entity: String, property: String) throws -> Kind {
        let unwrapped = unwrapOptionalMetatype(valueType)
        if unwrapped == String.self { return .string }
        if unwrapped == Bool.self { return .bool }
        if unwrapped == Int.self { return .int }
        if unwrapped == Int64.self { return .int64 }
        if unwrapped == Int32.self { return .int32 }
        if unwrapped == Double.self { return .double }
        if unwrapped == Float.self { return .float }
        if unwrapped == Date.self { return .date }
        if unwrapped == UUID.self { return .uuid }
        if unwrapped == Data.self { return .data }
        if let rawType = unwrapped as? any (RawRepresentable & Decodable & Encodable & Sendable).Type {
            return .rawRepresentable(
                type: rawType,
                rawKind: try rawKind(of: rawType, entity: entity, property: property)
            )
        }
        if let codableType = unwrapped as? any (Decodable & Encodable & Sendable).Type {
            return .codable(type: codableType)
        }
        throw PowerSyncSwiftDataError.unsupportedValueType(
            entity: entity,
            property: property,
            type: String(describing: valueType)
        )
    }

    private static func rawKind(
        of type: any (RawRepresentable & Decodable & Encodable & Sendable).Type,
        entity: String,
        property: String
    ) throws -> RawKind {
        func rawValueType<T: RawRepresentable>(_: T.Type) -> Any.Type { T.RawValue.self }
        let raw = rawValueType(type)
        if raw == String.self { return .string }
        if raw == Int.self { return .int }
        if raw == Int64.self { return .int64 }
        if raw == Int32.self { return .int32 }
        if raw == Double.self { return .double }
        throw PowerSyncSwiftDataError.unsupportedValueType(
            entity: entity,
            property: property,
            type: "\(type) (raw value \(raw))"
        )
    }

    /// The PowerSync column type for a property kind (used to derive PowerSync schemas).
    static func columnType(for kind: Kind) -> ColumnData {
        switch kind {
        case .string, .uuid, .data, .codable:
            return .text
        case .bool, .int, .int64, .int32:
            return .integer
        case .double, .float, .date:
            return .real
        case let .rawRepresentable(_, rawKind):
            switch rawKind {
            case .string: return .text
            case .int, .int64, .int32: return .integer
            case .double: return .real
            }
        }
    }

    // MARK: cursor -> value

    /// Reads a column from a PowerSync cursor as the Swift type backing `kind`.
    /// Returns `nil` for SQL `NULL`.
    static func value(
        from cursor: any SqlCursor,
        column: String,
        kind: Kind,
        entity: String,
        property: String
    ) throws -> (any DataStoreSnapshotValue)? {
        func exactInt<I: FixedWidthInteger & Decodable & Encodable & Sendable>(
            _: I.Type
        ) throws -> I? {
            guard let raw = try cursor.getInt64Optional(name: column) else { return nil }
            guard let exact = I(exactly: raw) else {
                throw PowerSyncSwiftDataError.valueOutOfRange(entity: entity, property: property)
            }
            return exact
        }
        switch kind {
        case .string:
            return try cursor.getStringOptional(name: column)
        case .bool:
            return try cursor.getBooleanOptional(name: column)
        case .int:
            return try exactInt(Int.self)
        case .int64:
            return try cursor.getInt64Optional(name: column)
        case .int32:
            return try exactInt(Int32.self)
        case .double:
            return try cursor.getDoubleOptional(name: column)
        case .float:
            return try cursor.getDoubleOptional(name: column).map { Float($0) }
        case .date:
            return try cursor.getDoubleOptional(name: column).map { Date(timeIntervalSince1970: $0) }
        case .uuid:
            return try cursor.getStringOptional(name: column).flatMap { UUID(uuidString: $0) }
        case .data:
            return try cursor.getStringOptional(name: column).flatMap { Data(base64Encoded: $0) }
        case let .rawRepresentable(type, rawKind):
            let raw: Any?
            switch rawKind {
            case .string: raw = try cursor.getStringOptional(name: column)
            case .int: raw = try exactInt(Int.self)
            case .int64: raw = try cursor.getInt64Optional(name: column)
            case .int32: raw = try exactInt(Int32.self)
            case .double: raw = try cursor.getDoubleOptional(name: column)
            }
            guard let raw else { return nil }
            return constructRawRepresentable(type, rawValue: raw)
        case let .codable(type):
            guard let json = try cursor.getStringOptional(name: column) else { return nil }
            return try decodeJSON(type, from: json)
        }
    }

    private static func constructRawRepresentable(
        _ type: any (RawRepresentable & Decodable & Encodable & Sendable).Type,
        rawValue: Any
    ) -> (any DataStoreSnapshotValue)? {
        func open<T: RawRepresentable & Decodable & Encodable & Sendable>(
            _: T.Type
        ) -> (any DataStoreSnapshotValue)? {
            guard let raw = rawValue as? T.RawValue else { return nil }
            return T(rawValue: raw).map { $0 as any DataStoreSnapshotValue }
        }
        return open(type)
    }

    private static func decodeJSON(
        _ type: any (Decodable & Encodable & Sendable).Type,
        from json: String
    ) throws -> any DataStoreSnapshotValue {
        func open<T: Decodable & Encodable & Sendable>(_: T.Type) throws -> any DataStoreSnapshotValue {
            try makeDecoder().decode(T.self, from: Data(json.utf8))
        }
        return try open(type)
    }

    // MARK: value -> SQL parameter

    /// Converts a snapshot value (or predicate constant) to a SQL statement parameter for
    /// its column kind. Booleans become `0`/`1` so the stored representation is
    /// deterministic.
    static func parameter(
        from value: Any?,
        kind: Kind,
        entity: String,
        property: String
    ) throws -> Sendable? {
        guard let value else { return nil }

        func mismatch() -> PowerSyncSwiftDataError {
            .unsupportedValueType(
                entity: entity,
                property: property,
                type: String(describing: type(of: value))
            )
        }

        switch kind {
        case .string:
            guard let v = value as? String else { throw mismatch() }
            return v
        case .bool:
            guard let v = value as? Bool else { throw mismatch() }
            return Int64(v ? 1 : 0)
        case .int:
            guard let v = value as? Int else { throw mismatch() }
            return Int64(v)
        case .int64:
            guard let v = value as? Int64 else { throw mismatch() }
            return v
        case .int32:
            guard let v = value as? Int32 else { throw mismatch() }
            return Int64(v)
        case .double:
            guard let v = value as? Double else { throw mismatch() }
            return v
        case .float:
            guard let v = value as? Float else { throw mismatch() }
            return Double(v)
        case .date:
            guard let v = value as? Date else { throw mismatch() }
            return v.timeIntervalSince1970
        case .uuid:
            guard let v = value as? UUID else { throw mismatch() }
            // Lowercase: backends (Postgres) render uuids lowercase and SQLite text
            // comparison is case-sensitive, so storage and bindings must agree.
            return v.uuidString.lowercased()
        case .data:
            guard let v = value as? Data else { throw mismatch() }
            return v.base64EncodedString()
        case let .rawRepresentable(_, rawKind):
            guard let representable = value as? any RawRepresentable else { throw mismatch() }
            let raw = representable.rawValue
            switch rawKind {
            case .string:
                guard let v = raw as? String else { throw mismatch() }
                return v
            case .int:
                guard let v = raw as? Int else { throw mismatch() }
                return Int64(v)
            case .int64:
                guard let v = raw as? Int64 else { throw mismatch() }
                return v
            case .int32:
                guard let v = raw as? Int32 else { throw mismatch() }
                return Int64(v)
            case .double:
                guard let v = raw as? Double else { throw mismatch() }
                return v
            }
        case .codable:
            guard let encodable = value as? any Encodable else { throw mismatch() }
            func open<T: Encodable>(_ v: T) throws -> String {
                String(decoding: try makeEncoder().encode(v), as: UTF8.self)
            }
            return try open(encodable)
        }
    }

    // MARK: JSON strategies (stable on-disk format for codable attributes)

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return decoder
    }
}
