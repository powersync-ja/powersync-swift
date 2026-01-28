import PowerSyncKotlin

/// Converts a Swift `JsonValue` to one accepted by the Kotlin SDK
extension JsonValue {
    func toKotlinMap() -> PowerSyncKotlin.JsonParam {
        switch self {
        case .string(let value):
            return PowerSyncKotlin.JsonParam.String(value: value)
        case .int(let value):
            return PowerSyncKotlin.JsonParam.Number(value: value)
        case .double(let value):
            return PowerSyncKotlin.JsonParam.Number(value: value)
        case .bool(let value):
            return PowerSyncKotlin.JsonParam.Boolean(value: value)
        case .null:
            return PowerSyncKotlin.JsonParam.Null()
        case .array(let array):
            return PowerSyncKotlin.JsonParam.Collection(
                value: array.map { $0.toKotlinMap() }
            )
        case .object(let dict):
            var anyDict: [String: PowerSyncKotlin.JsonParam] = [:]
            for (key, value) in dict {
                anyDict[key] = value.toKotlinMap()
            }
            return PowerSyncKotlin.JsonParam.Map(value: anyDict)
        }
    }
    
    static func kotlinValueToJsonParam(raw: Any?) -> JsonValue {
        if let string = raw as? String {
            return Self.string(string)
        } else if let bool = raw as? KotlinBoolean {
            return Self.bool(bool.boolValue)
        } else if let int = raw as? KotlinInt {
            return Self.int(int.intValue)
        } else if let double = raw as? KotlinDouble {
            return Self.double(double.doubleValue)
        } else if let array = raw as? [Any?] {
            return Self.array(array.map(kotlinValueToJsonParam))
        } else if let object = raw as? [String: Any?] {
            return Self.object(object.mapValues(kotlinValueToJsonParam))
        } else {
            // fatalError is fine here because this function is internal, so this being reached
            // is an SDK bug.
            fatalError("fromValue must only be called on outputs of JsonValue.toValue()");
        }
    }
}
