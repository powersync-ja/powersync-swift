import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Pins the private SwiftData surfaces the integration relies on, so an SDK update that
/// changes them fails loudly here instead of producing silent data loss.
@Suite("SDK drift guards")
struct SDKDriftGuardTests {
    /// The only reliable source of attribute key paths is reflecting
    /// `PersistentModel.schemaMetadata` with the child labels `name`/`keypath`. If an SDK
    /// update renames them, this fails with a precise message instead of empty snapshots.
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func schemaMetadataMirrorShapeIsStable() throws {
        let metadata = Note.schemaMetadata
        #expect(!metadata.isEmpty)
        for property in metadata {
            let labels = Set(Mirror(reflecting: property).children.compactMap(\.label))
            #expect(
                labels.contains("name") && labels.contains("keypath"),
                "Schema.PropertyMetadata children renamed (\(labels)); ModelPropertyReflection must be updated"
            )
        }
        let reflected = ModelPropertyReflection.properties(for: Note.self)
        #expect(Set(reflected.map(\.name)) == ["id", "title", "done", "count"])
    }

    /// `PersistentIdentifier` is decoded through its private Codable envelope
    /// (`implementation.primaryKey`) to recover the PowerSync id. If the encoding changes,
    /// this fails before anything else does.
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func persistentIdentifierEnvelopeIsStable() throws {
        let identifier = try PersistentIdentifier.identifier(
            for: "drift-guard",
            entityName: "Note",
            primaryKey: "abc-123"
        )
        #expect(try identifier.powerSyncPrimaryKey() == "abc-123")
        #expect(identifier.entityName == "Note")
        #expect(identifier.storeIdentifier == "drift-guard")
    }

    /// The snapshot encodes values under `DataStoreSnapshotCodingKey.modeledProperty`;
    /// SwiftData's model decoder matches them by property name through `stringValue`.
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func modeledPropertyCodingKeyRoundTrips() throws {
        let key = DataStoreSnapshotCodingKey.modeledProperty("title")
        let reconstructed = DataStoreSnapshotCodingKey(stringValue: key.stringValue)
        guard case let .modeledProperty(name) = reconstructed else {
            Issue.record("stringValue \(key.stringValue) no longer reconstructs a modeledProperty key")
            return
        }
        #expect(name == "title")
    }

    // MARK: runtime drift defenses

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func mintCacheResolvesPrimaryKeysWithoutTheEnvelope() throws {
        let before = PrimaryKeyResolver._testCacheCount
        let identifier = try PrimaryKeyResolver.mint(
            store: "drift-cache",
            entityName: "Note",
            primaryKey: "pk-123"
        )
        #expect(try PrimaryKeyResolver.primaryKey(of: identifier) == "pk-123")
        #expect(PrimaryKeyResolver._testCacheCount > before)
    }

    /// Simulated reflection drift on a dedicated model: the first fetch fails with a
    /// descriptive error instead of materializing garbage, and a save of an extracted-empty
    /// snapshot fails instead of persisting empty rows.
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func simulatedReflectionDriftFailsDescriptively() async throws {
        let database = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [DriftProbe.self]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        let container = try ModelContainer(
            for: SwiftData.Schema([DriftProbe.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "drift-probe", database: database)]
        )

        ModelPropertyReflection._testSuppressMirrorKeyPaths(for: DriftProbe.self, true)
        defer {
            ModelPropertyReflection._testSuppressMirrorKeyPaths(for: DriftProbe.self, false)
            ReflectionHealth._testReset()
        }

        // Read path: descriptive failure on first fetch.
        do {
            _ = try ModelContext(container).fetch(FetchDescriptor<DriftProbe>())
            Issue.record("fetch should fail under reflection drift")
        } catch {
            #expect(String(describing: error).contains("key paths"))
        }

        // Write path: the snapshot extracts empty, and save() refuses to persist it.
        let writer = ModelContext(container)
        writer.insert(DriftProbe(id: "d1", value: 1))
        #expect(throws: (any Error).self) {
            try writer.save()
        }
        let stored = try await database.get(
            sql: "SELECT COUNT(*) FROM drift_probe",
            parameters: []
        ) { try $0.getInt(index: 0) }
        #expect(stored == 0)

        try await database.close()
    }

    /// A model that provides its key paths through PUBLIC API keeps working even when
    /// mirrored key paths are gone.
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func publiclyProvidedKeyPathsSurviveReflectionDrift() async throws {
        let database = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [DriftSafe.self]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        let container = try ModelContainer(
            for: SwiftData.Schema([DriftSafe.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "drift-safe", database: database)]
        )

        ModelPropertyReflection._testSuppressMirrorKeyPaths(for: DriftSafe.self, true)
        defer { ModelPropertyReflection._testSuppressMirrorKeyPaths(for: DriftSafe.self, false) }

        let context = ModelContext(container)
        context.insert(DriftSafe(id: "s1", label: "publica"))
        try context.save()
        let fetched = try ModelContext(container).fetch(FetchDescriptor<DriftSafe>())
        #expect(fetched.first?.label == "publica")

        try await database.close()
    }
}
