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
}
