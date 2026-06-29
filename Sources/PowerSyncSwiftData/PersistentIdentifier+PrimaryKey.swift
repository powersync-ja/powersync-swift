import Foundation
import SwiftData

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PersistentIdentifier {
    /// Extracts the primary key backing this identifier.
    ///
    /// `PersistentIdentifier` is opaque, but it is `Codable`; encoding it produces the
    /// private envelope `{"implementation": {"primaryKey": ...}}`. Identifiers minted by
    /// ``PowerSyncDataStore`` always carry the PowerSync `id` string. The format is pinned
    /// by an SDK-drift guard test.
    func powerSyncPrimaryKey() throws -> String {
        let data = try JSONEncoder().encode(self)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.implementation.primaryKey.stringValue
    }

    private struct Envelope: Decodable {
        let implementation: Implementation
    }

    private struct Implementation: Decodable {
        let primaryKey: PrimaryKey
    }

    private enum PrimaryKey: Decodable {
        case string(String)
        case int(Int64)
        case uint(UInt64)
        case double(Double)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .int(value)
            } else if let value = try? container.decode(UInt64.self) {
                self = .uint(value)
            } else if let value = try? container.decode(Double.self) {
                self = .double(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported primary key representation"
                )
            }
        }

        var stringValue: String {
            switch self {
            case let .string(value): return value
            case let .int(value): return String(value)
            case let .uint(value): return String(value)
            case let .double(value): return String(value)
            }
        }
    }
}
