import Foundation
import SwiftData
import Synchronization

/// Recovers the typed `AnyKeyPath` for each stored property of a `@Model`.
///
/// Sources, in order of preference:
/// 1. **Public**: if the model conforms to Foundation's `PredicateCodableKeyPathProviding`
///    with property names as keys, those key paths are used directly — no reflection.
/// 2. **Reflection**: `PersistentModel.schemaMetadata` (the array the `@Model` macro
///    generates) read with `Mirror` using the child labels `name`/`keypath`.
///    `Schema.Attribute` exposes no key path publicly (unlike `Schema.Relationship`), so
///    this is the default source for attributes.
///
/// The reflection coupling is defended in depth: drift-guard tests pin the labels, and
/// ``validateCoverage(of:entity:)`` runs at first use in production so an SDK change
/// surfaces as a descriptive startup error instead of silent data loss.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
enum ModelPropertyReflection {
    /// A stored property reflected from `schemaMetadata` (or provided publicly).
    /// `AnyKeyPath` is immutable and safe to share across threads.
    struct Property: @unchecked Sendable {
        let name: String
        let keyPath: AnyKeyPath
    }

    private static let cache = Mutex<[ObjectIdentifier: [Property]]>([:])

    /// Test-only: simulates an SDK that stopped exposing mirrored key paths for the given
    /// type names, so the runtime failure paths can be exercised.
    private static let suppressedMirrorTypes = Mutex<Set<String>>([])

    static func _testSuppressMirrorKeyPaths<M: PersistentModel>(for modelType: M.Type, _ suppressed: Bool) {
        let name = String(describing: modelType)
        suppressedMirrorTypes.withLock { storage in
            if suppressed {
                storage.insert(name)
            } else {
                storage.remove(name)
            }
        }
        cache.withLock { $0[ObjectIdentifier(modelType)] = nil }
    }

    static func properties(for modelType: any PersistentModel.Type) -> [Property] {
        let key = ObjectIdentifier(modelType)
        if let cached = cache.withLock({ $0[key] }) {
            return cached
        }

        let mirrorSuppressed = suppressedMirrorTypes.withLock {
            $0.contains(String(describing: modelType))
        }
        let provided = providedKeyPaths(of: modelType)

        var properties: [Property] = []
        for propertyMetadata in modelType.schemaMetadata {
            var name: String?
            var keyPath: AnyKeyPath?
            for child in Mirror(reflecting: propertyMetadata).children {
                switch child.label {
                case "name":
                    name = child.value as? String
                case "keypath":
                    keyPath = child.value as? AnyKeyPath
                default:
                    break
                }
            }
            guard let name else {
                continue
            }
            // `Schema.Index` and `Schema.Unique` metadata entries carry placeholder key
            // paths and are not stored properties.
            if name.hasPrefix("SwiftData.Schema.") {
                continue
            }
            if mirrorSuppressed {
                keyPath = nil
            }
            // A publicly provided key path takes precedence over the reflected one.
            guard let resolved = provided[name] ?? keyPath else {
                continue
            }
            properties.append(Property(name: name, keyPath: resolved))
        }
        if !mirrorSuppressed {
            cache.withLock { $0[key] = properties }
        }
        return properties
    }

    /// Throws when reflection (plus public providers) does not cover every stored
    /// attribute of the entity — the descriptive runtime tripwire for SDK drift.
    static func validateCoverage(of modelType: any PersistentModel.Type, entity: EntityMapping) throws {
        let reflected = Set(properties(for: modelType).map(\.name))
        var missing: [String] = []
        if !reflected.contains(entity.idPropertyName) {
            missing.append(entity.idPropertyName)
        }
        for property in entity.properties where !reflected.contains(property.name) {
            missing.append(property.name)
        }
        guard missing.isEmpty else {
            throw PowerSyncSwiftDataError.sdkDriftDetected(
                detail: "schemaMetadata reflection lost the key paths of \(entity.entityName): "
                    + missing.joined(separator: ", ")
                    + ". Conforming \(entity.entityName) to PredicateCodableKeyPathProviding "
                    + "(keys = property names) restores them through public API."
            )
        }
    }

    private static func providedKeyPaths(of modelType: any PersistentModel.Type) -> [String: AnyKeyPath] {
        guard let providing = modelType as? any PredicateCodableKeyPathProviding.Type else {
            return [:]
        }
        func open<P: PredicateCodableKeyPathProviding>(_: P.Type) -> [String: AnyKeyPath] {
            P.predicateCodableKeyPaths.mapValues { $0 as AnyKeyPath }
        }
        return open(providing)
    }
}

/// Tracks entities whose snapshots could not be extracted (no id value despite a known
/// mapping): the symptom of broken key-path reflection during `init(from:)`, which cannot
/// throw. ``PowerSyncDataStore/save(_:)`` consults this before writing, so drift fails the
/// save descriptively instead of persisting empty rows.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
enum ReflectionHealth {
    private static let flagged = Mutex<Set<String>>([])

    static func flagExtractionFailure(entityName: String) {
        flagged.withLock { _ = $0.insert(entityName) }
    }

    static func assertHealthy(entityName: String) throws {
        let isFlagged = flagged.withLock { $0.contains(entityName) }
        if isFlagged {
            throw PowerSyncSwiftDataError.sdkDriftDetected(
                detail: "snapshot extraction produced no values for \(entityName); "
                    + "key-path reflection appears broken (see PowerSyncSwiftData README)"
            )
        }
    }

    static func _testReset() {
        flagged.withLock { $0.removeAll() }
    }
}
