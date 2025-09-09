/// A strongly-typed representation of a JSON value.
///
/// Supports all standard JSON types: string, number (integer and double),
/// boolean, null, arrays, and nested objects.
public enum JsonValue: Codable, Sendable {
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
}

/// A typealias representing a top-level JSON object with string keys and `JSONValue` values.
public typealias JsonParam = [String: JsonValue]
