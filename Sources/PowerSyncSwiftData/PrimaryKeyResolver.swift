import SwiftData
import Synchronization

/// Mints persistent identifiers and resolves them back to PowerSync primary keys.
///
/// Every identifier that enters the system is minted here (fetch, save remapping,
/// relationships, cached snapshots), and its primary key is remembered. Resolution is
/// served from that in-process cache first, so the identifier's private Codable envelope
/// (``PersistentIdentifier/powerSyncPrimaryKey()``) is only a fallback for identifiers
/// minted before an eviction — the integration no longer depends on it on hot paths.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
enum PrimaryKeyResolver {
    private static let cache = Mutex<[PersistentIdentifier: String]>([:])

    /// Mints an identifier and remembers its primary key.
    static func mint(
        store: String,
        entityName: String,
        primaryKey: String
    ) throws -> PersistentIdentifier {
        let identifier = try PersistentIdentifier.identifier(
            for: store,
            entityName: entityName,
            primaryKey: primaryKey
        )
        cache.withLock { storage in
            // Crude bound: reset rather than grow without limit. Evicted identifiers
            // still resolve through the envelope fallback.
            if storage.count >= 200_000 {
                storage.removeAll(keepingCapacity: true)
            }
            storage[identifier] = primaryKey
        }
        return identifier
    }

    /// Resolves an identifier's primary key: mint cache first, Codable envelope fallback.
    static func primaryKey(of identifier: PersistentIdentifier) throws -> String {
        if let cached = cache.withLock({ $0[identifier] }) {
            return cached
        }
        let resolved = try identifier.powerSyncPrimaryKey()
        cache.withLock { $0[identifier] = resolved }
        return resolved
    }

    static var _testCacheCount: Int {
        cache.withLock { $0.count }
    }
}
