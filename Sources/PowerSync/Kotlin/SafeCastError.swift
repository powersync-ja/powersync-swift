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

internal func safeCast<T>(_ value: Any?, to type: T.Type) throws -> T {
    if let castedValue = value as? T {
        return castedValue
    } else {
        throw SafeCastError.typeMismatch(expected: type, actual: value)
    }
}
