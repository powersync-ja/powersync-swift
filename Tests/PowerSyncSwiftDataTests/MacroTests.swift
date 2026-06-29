import Foundation
import PowerSync
import PowerSyncSwiftDataMacros
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// A model whose key paths are provided through public API by the @PowerSyncModel macro.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
@PowerSyncModel
final class MacroNote {
    var id: String
    var title: String
    var count: Int
    @Transient
    var scratch: Int = 0

    init(id: String, title: String, count: Int) {
        self.id = id
        self.title = title
        self.count = count
    }
}

/// The @PowerSyncModel macro: generated conformance, stored-property coverage (skipping
/// @Transient), and independence from mirrored KEY PATHS (property names still come from
/// schemaMetadata, guarded by the runtime coverage check).
@Suite("PowerSyncModel macro")
struct MacroTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func generatesTheConformanceWithStoredPropertiesOnly() throws {
        let providing = try #require(MacroNote.self as? any PredicateCodableKeyPathProviding.Type)
        func keys<P: PredicateCodableKeyPathProviding>(_: P.Type) -> Set<String> {
            Set(P.predicateCodableKeyPaths.keys)
        }
        #expect(keys(providing) == ["id", "title", "count"])
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func macroModelWorksWithReflectionGone() async throws {
        let database = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [MacroNote.self]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        let container = try ModelContainer(
            for: SwiftData.Schema([MacroNote.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "macro-model", database: database)]
        )

        // Even with mirrored key paths suppressed, the macro-provided ones carry the
        // whole round trip: insert, upload capture, fetch, predicate translation.
        ModelPropertyReflection._testSuppressMirrorKeyPaths(for: MacroNote.self, true)
        defer { ModelPropertyReflection._testSuppressMirrorKeyPaths(for: MacroNote.self, false) }

        let context = ModelContext(container)
        context.insert(MacroNote(id: "m1", title: "macro", count: 7))
        try context.save()

        let transaction = try #require(try await database.getNextCrudTransaction())
        #expect(transaction.crud.first?.opData?["title"] == "macro")

        let fetched = try ModelContext(container).fetch(FetchDescriptor<MacroNote>(
            predicate: #Predicate { $0.count > 5 }
        ))
        #expect(fetched.first?.title == "macro")
        #expect(fetched.first?.scratch == 0)

        try await database.close()
    }
}
