/// A strongly-typed representation of a JSON value.
///
/// Supports all standard JSON types: string, number (integer and double),
/// boolean, null, arrays, and nested objects.
public enum JSONValue: Codable {
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
    case array([JSONValue])
    
    /// A JSON object containing key-value pairs where values are `JSONValue` instances.
    case object([String: JSONValue])
    
    /// Converts the `JSONValue` into a native Swift representation.
    ///
    /// - Returns: A corresponding Swift type (`String`, `Int`, `Double`, `Bool`, `nil`, `[Any]`, or `[String: Any]`),
    ///            or `nil` if the value is `.null`.
    func toValue() -> Any? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return nil
        case .array(let array):
            return array.map { $0.toValue() }
        case .object(let dict):
            var anyDict: [String: Any] = [:]
            for (key, value) in dict {
                anyDict[key] = value.toValue()
            }
            return anyDict
        }
    }
}

/// A typealias representing a top-level JSON object with string keys and `JSONValue` values.
public typealias JsonParam = [String: JSONValue]
