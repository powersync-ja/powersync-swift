#if POWERSYNC_DEVTOOLS && canImport(Network) && !os(watchOS)
import Foundation
import PowerSync

extension JsonValue {
    func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }

    static func parse(_ data: Data) -> JsonValue? {
        try? JSONDecoder().decode(JsonValue.self, from: data)
    }

    /// Re-reads any `Encodable` value (such as the schema) as JSON.
    static func from<T: Encodable>(_ value: T) -> JsonValue {
        guard let data = try? JSONEncoder().encode(value) else { return .null }
        return parse(data) ?? .null
    }

    subscript(key: String) -> JsonValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(value)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var arrayValue: [JsonValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JsonValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The value as a SQL parameter.
    var sqlParameter: Sendable? {
        switch self {
        case .string(let value): value
        case .int(let value): Int64(value)
        case .double(let value): value
        case .bool(let value): value ? Int64(1) : Int64(0)
        case .null: nil
        case .array, .object: String(decoding: jsonData(), as: UTF8.self)
        }
    }

    static func optional(_ value: String?) -> JsonValue { value.map { .string($0) } ?? .null }
    static func optional(_ value: Int?) -> JsonValue { value.map { .int($0) } ?? .null }
    static func optional(_ value: Bool?) -> JsonValue { value.map { .bool($0) } ?? .null }
}

// Literals keep the hand-written protocol and MCP payloads readable.
extension JsonValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JsonValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JsonValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension PowerSyncDataType {
    /// The value as JSON. Blobs become `{ "binary": "<base64>" }`, as in the Dart SDK.
    var json: JsonValue {
        switch self {
        case .bool(let value): .bool(value)
        case .string(let value): .string(value)
        case .int64(let value): .int(Int(value))
        case .int32(let value): .int(Int(value))
        case .double(let value): .double(value)
        case .data(let value): .object(["binary": .string(value.base64EncodedString())])
        }
    }
}

/// Epoch milliseconds, the protocol's time unit.
func epochMillis(_ date: Date?) -> JsonValue {
    date.map { .int(Int($0.timeIntervalSince1970 * 1000)) } ?? .null
}

func epochMillis(_ seconds: TimeInterval?) -> JsonValue {
    seconds.map { .int(Int($0 * 1000)) } ?? .null
}
#endif
