import Foundation

enum SafeCastError: Error, CustomStringConvertible {
    case typeMismatch(expected: Any.Type, actual: Any?)

    var description: String {
        switch self {
        case let .typeMismatch(expected, actual):
            let actualType = actual.map { String(describing: type(of: $0)) } ?? "nil"
            return "Type mismatch: Expected \(expected), but got \(actualType)."
        }
    }
}

func safeCast<T>(_ value: Any?, to type: T.Type) throws -> T {
    // Special handling for nil when T is an optional type
    if value == nil || value is NSNull {
        // Check if T is an optional type that can accept nil
        let nilValue: Any? = nil
        if let nilAsT = nilValue as? T {
            return nilAsT
        }
    }

    if let castedValue = value as? T {
        return castedValue
    } else {
        throw SafeCastError.typeMismatch(expected: type, actual: value)
    }
}
