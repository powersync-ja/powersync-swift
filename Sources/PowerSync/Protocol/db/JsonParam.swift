/// A strongly-typed representation of a JSON value.
///
/// Supports all standard JSON types: string, number (integer and double),
/// boolean, null, arrays, and nested objects.
public enum JsonValue: Codable, Sendable, Equatable, Hashable {
    /// A JSON string value.
    case string(String)

    /// A JSON integer value.
    case int(Int)

    /// A JSON double-precision floating-point value.
    case double(Double)

    /// A JSON boolean value (`true` or `false`).
    case bool(Bool)

    /// A JSON null value.
    case null

    /// A JSON array containing a list of `JSONValue` elements.
    case array([JsonValue])

    /// A JSON object containing key-value pairs where values are `JSONValue` instances.
    case object([String: JsonValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                              { self = .null }
        else if let b = try? c.decode(Bool.self)      { self = .bool(b) }
        else if let i = try? c.decode(Int.self)       { self = .int(i) }
        else if let d = try? c.decode(Double.self)    { self = .double(d) }
        else if let s = try? c.decode(String.self)    { self = .string(s) }
        else if let a = try? c.decode([JsonValue].self)         { self = .array(a) }
        else if let o = try? c.decode([String: JsonValue].self) { self = .object(o) }
        else {
            throw DecodingError.typeMismatch(
                JsonValue.self,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected any JSON value"))
        }
    }

    /// Converts the `JSONValue` into a native Swift representation.
    ///
    /// - Returns: A corresponding Swift type (`String`, `Int`, `Double`, `Bool`, `nil`, `[Any]`, or `[String: Any]`),
    ///            or `nil` if the value is `.null`.
    func toValue() -> Any? {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .bool(value):
            return value
        case .null:
            return nil
        case let .array(array):
            return array.map { $0.toValue() }
        case let .object(dict):
            var anyDict: [String: Any] = [:]
            for (key, value) in dict {
                anyDict[key] = value.toValue()
            }
            return anyDict
        }
    }
    
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try c.encode(value)
        case .int(let value):
            try c.encode(value)
        case .double(let value):
            try c.encode(value)
        case .bool(let value):
            try c.encode(value)
        case .null:
            try c.encodeNil()
        case .array(let values):
            try c.encode(values)
        case .object(let object):
            try c.encode(object)
        }
    }
}

/// A typealias representing a top-level JSON object with string keys and `JSONValue` values.
public typealias JsonParam = [String: JsonValue]
