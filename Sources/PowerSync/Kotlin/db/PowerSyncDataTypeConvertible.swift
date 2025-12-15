import struct Foundation.Data

/// Represents the set of types that are supported
/// by the PowerSync Kotlin Multiplatform SDK
public enum PowerSyncDataType {
    case bool(Bool)
    case string(String)
    case int64(Int64)
    case int32(Int32)
    case double(Double)
    case data(Data)
}

/// Types conforming to this protocol will be
/// mapped to the specified ``PowerSyncDataType``
/// before use by SQLite
public protocol PowerSyncDataTypeConvertible {
    var psDataType: PowerSyncDataType? { get }
}

extension PowerSyncDataType {
    func unwrap() -> Any {
        switch self {
            case let .bool(bool): bool
            case let .string(string): string
            case let .int32(int32): int32
            case let .int64(int64): int64
            case let .double(double): double
            case let .data(data): data
        }
    }
}