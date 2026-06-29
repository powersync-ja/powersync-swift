import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Closes the asserted-but-untested gaps found by the module audit: real reference cycles
/// in one save, many-to-many through an explicit join model, the transformable rejection
/// path, in-memory fallback behavior for count/identifiers/batch delete, and ModelContext
/// lifecycle smoke coverage (rollback, enumerate, model(for:)).
@Suite("Coverage gaps")
struct CoverageGapsTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func referenceCycleInOneSaveRemapsBothDirections() async throws {
        let database = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [Twin.self]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        let container = try ModelContainer(
            for: SwiftData.Schema([Twin.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "cycle", database: database)]
        )

        // A true cycle: both models reference each other and BOTH carry empty ids, so
        // both references point at temporary identifiers that must be remapped.
        let context = ModelContext(container)
        let castor = Twin(id: "", name: "Castor")
        let pollux = Twin(id: "", name: "Pollux")
        castor.partner = pollux
        pollux.partner = castor
        context.insert(castor)
        context.insert(pollux)
        try context.save()

        let reader = ModelContext(container)
        let twins = try reader.fetch(FetchDescriptor<Twin>())
        #expect(twins.count == 2)
        let byName = Dictionary(uniqueKeysWithValues: twins.map { ($0.name, $0) })
        #expect(byName["Castor"]?.partner?.name == "Pollux")
        #expect(byName["Pollux"]?.partner?.name == "Castor")
        #expect(byName["Castor"]?.partner?.id == byName["Pollux"]?.id)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func manyToManyThroughJoinModelRoundTrips() async throws {
        let database = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [Student.self, Course.self, Enrollment.self]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        let container = try ModelContainer(
            for: SwiftData.Schema([Student.self, Course.self, Enrollment.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "join-m2m", database: database)]
        )

        // Three entities inserted in the same save, joined through Enrollment.
        let context = ModelContext(container)
        let ada = Student(id: "s1", name: "Ada")
        let alan = Student(id: "s2", name: "Alan")
        let logic = Course(id: "c1", title: "Logic")
        let crypto = Course(id: "c2", title: "Crypto")
        context.insert(ada)
        context.insert(alan)
        context.insert(logic)
        context.insert(crypto)
        context.insert(Enrollment(id: "e1", student: ada, course: logic))
        context.insert(Enrollment(id: "e2", student: ada, course: crypto))
        context.insert(Enrollment(id: "e3", student: alan, course: crypto))
        try context.save()

        let reader = ModelContext(container)
        let students = try reader.fetch(FetchDescriptor<Student>(sortBy: [SortDescriptor(\.name)]))
        let adaCourses = Set(students[0].enrollments.compactMap(\.course?.title))
        #expect(adaCourses == ["Logic", "Crypto"])
        let cryptoStudents = try reader.fetch(
            FetchDescriptor<Course>(predicate: #Predicate { $0.id == "c2" })
        ).first?.enrollments.compactMap(\.student?.name)
        #expect(Set(cryptoStudents ?? []) == ["Ada", "Alan"])

        // Unenrolling deletes only the join row.
        let enrollment = try #require(try reader.fetch(
            FetchDescriptor<Enrollment>(predicate: #Predicate { $0.id == "e2" })
        ).first)
        reader.delete(enrollment)
        try reader.save()

        let verifier = ModelContext(container)
        let adaAfter = try #require(try verifier.fetch(
            FetchDescriptor<Student>(predicate: #Predicate { $0.id == "s1" })
        ).first)
        #expect(adaAfter.enrollments.compactMap(\.course?.title) == ["Logic"])
        #expect(try verifier.fetchCount(FetchDescriptor<Course>()) == 2)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func transformableAttributesAreRejectedDescriptively() throws {
        let entity = SwiftData.Schema.Entity("Sketch")
        entity.storedProperties = [
            SwiftData.Schema.Attribute(name: "id", valueType: String.self),
            SwiftData.Schema.Attribute(
                name: "shape",
                options: [.transformable(by: "MissingTransformer")],
                valueType: Data.self
            ),
        ]
        do {
            _ = try SchemaMapper(
                schema: SwiftData.Schema(entity),
                tableNameForEntity: PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:)
            )
            Issue.record("transformable attribute should be rejected")
        } catch {
            #expect(String(describing: error).contains("transformable"))
        }
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func untranslatablePredicatesFallBackForCountIdentifiersAndBatchDelete() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "fallback-paths", database: database)]
        )
        let context = ModelContext(container)
        for (index, title) in ["alfa", "bravo", "carlos"].enumerated() {
            context.insert(Note(id: "n\(index)", title: title, done: false, count: index))
        }
        try context.save()

        // localizedStandardContains is untranslatable on purpose. SwiftData only applies
        // the in-memory fallback to fetch(); for count, identifiers and batch delete the
        // error PROPAGATES — this test pins that contract (documented in the README, with
        // fetch-based workarounds).
        let predicate = #Predicate<Note> { $0.title.localizedStandardContains("AR") }
        let reader = ModelContext(container)

        #expect(throws: DataStoreError.preferInMemoryFilter) {
            _ = try reader.fetchCount(FetchDescriptor<Note>(predicate: predicate))
        }
        #expect(throws: DataStoreError.preferInMemoryFilter) {
            _ = try reader.fetchIdentifiers(FetchDescriptor<Note>(predicate: predicate))
        }
        #expect(throws: DataStoreError.preferInMemoryFilter) {
            try reader.delete(model: Note.self, where: predicate)
        }

        // The fetch-based workaround stays correct through the in-memory fallback.
        let matches = try reader.fetch(FetchDescriptor<Note>(predicate: predicate))
        #expect(matches.count == 1)
        for model in matches {
            reader.delete(model)
        }
        try reader.save()
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Note>())
        #expect(Set(remaining.map(\.title)) == ["alfa", "bravo"])

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func modelContextLifecycleSmoke() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "lifecycle", database: database)]
        )

        // rollback() discards pending inserts and the stored row keeps the saved value.
        // Whether the in-memory edit survives on the model instance is platform-dependent
        // (macOS keeps "editada", iOS refaults to "guardada" through cachedSnapshots);
        // DefaultStore shows the same divergence, so only the invariants are pinned.
        let context = ModelContext(container)
        let note = Note(id: "n1", title: "guardada", done: false, count: 1)
        context.insert(note)
        try context.save()
        note.title = "editada"
        context.insert(Note(id: "n2", title: "pendiente", done: false, count: 2))
        context.rollback()
        #expect(note.title == "editada" || note.title == "guardada")
        #expect(try context.fetchCount(FetchDescriptor<Note>()) == 1)
        let storedTitle = try await database.get(
            sql: "SELECT title FROM note WHERE id = ?",
            parameters: ["n1"]
        ) { try $0.getString(index: 0) }
        #expect(storedTitle == "guardada")

        // enumerate() walks batched results through the store.
        let extra = ModelContext(container)
        for index in 0 ..< 25 {
            extra.insert(Note(id: "bulk-\(index)", title: "b\(index)", done: false, count: index))
        }
        try extra.save()
        var enumerated = 0
        try ModelContext(container).enumerate(FetchDescriptor<Note>(), batchSize: 10) { (_: Note) in
            enumerated += 1
        }
        #expect(enumerated == 26)

        // model(for:) returns the registered instance for a known identifier.
        let reader = ModelContext(container)
        let fetched = try #require(try reader.fetch(
            FetchDescriptor<Note>(predicate: #Predicate { $0.id == "n1" })
        ).first)
        let viaIdentifier = reader.model(for: fetched.persistentModelID) as? Note
        #expect(viaIdentifier?.id == "n1")

        try await database.close()
    }
}
