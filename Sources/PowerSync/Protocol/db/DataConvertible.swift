import Foundation

// Represents the set of types that are supported
/// by the PowerSync Kotlin Multiplatform SDK
public enum PowerSyncDataType {
    case bool(Bool)
    case string(String)
    case int64(Int64)
    case int32(Int32)
    case double(Double)
    case data(Data)
}

extension PowerSyncDataType {
    init(from: Any) throws (PowerSyncError) {
        if let bool = from as? Bool {
            self = .bool(bool)
            return
        }
        if let string = from as? String {
            self = .string(string)
            return
        }
        if let int = from as? Int64 {
            self = .int64(int)
            return
        }
        if let int = from as? Int {
            self = .int64(Int64(int))
            return
        }
        if let int = from as? Int32 {
            self = .int32(int)
            return
        }
        if let double = from as? Double {
            self = .double(double)
            return
        }
        if let data = from as? Data {
            self = .data(data)
            return
        }
        
        throw .operationFailed(message: "Invalid parameter, expected Bool, String, Int64, Int32, Double or Data")
    }
}

/// Types conforming to this protocol will be
/// mapped to the specified ``PowerSyncDataType``
/// before use by SQLite
public protocol PowerSyncDataTypeConvertible {
    var psDataType: PowerSyncDataType? { get }
}
