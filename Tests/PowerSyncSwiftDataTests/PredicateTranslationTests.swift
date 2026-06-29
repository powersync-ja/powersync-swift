import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// `FetchDescriptor` translation — predicates to SQL WHERE, sort descriptors to
/// ORDER BY, limit/offset, count and identifiers; in-memory fallback only for nodes the
/// translator does not support.
@Suite("Predicate translation")
struct PredicateTranslationTests {
    // MARK: translator units

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    private static func noteTranslator() throws -> PredicateTranslator {
        let mapper = try SchemaMapper(
            schema: SwiftData.Schema([Note.self]),
            tableNameForEntity: PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:)
        )
        return PredicateTranslator(
            entity: try mapper.entity(named: "Note"),
            modelType: Note.self
        )
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    private static func typeMixTranslator() throws -> PredicateTranslator {
        let mapper = try SchemaMapper(
            schema: SwiftData.Schema([TypeMix.self]),
            tableNameForEntity: PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:)
        )
        return PredicateTranslator(
            entity: try mapper.entity(named: "TypeMix"),
            modelType: TypeMix.self
        )
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func translatesEqualAndComparisons() throws {
        let translator = try Self.noteTranslator()

        let equal = try translator.translateWhere(#Predicate<Note> { $0.title == "hola" })
        #expect(equal.clause == "\"title\" = ?")
        #expect(equal.bindings.count == 1)
        #expect(equal.bindings[0] as? String == "hola")

        let notEqual = try translator.translateWhere(#Predicate<Note> { $0.title != "hola" })
        #expect(notEqual.clause == "\"title\" != ?")

        let less = try translator.translateWhere(#Predicate<Note> { $0.count < 5 })
        #expect(less.clause == "\"count\" < ?")
        #expect(less.bindings[0] as? Int64 == 5)

        let greaterOrEqual = try translator.translateWhere(#Predicate<Note> { $0.count >= 5 })
        #expect(greaterOrEqual.clause == "\"count\" >= ?")

        let flipped = try translator.translateWhere(#Predicate<Note> { 5 > $0.count })
        #expect(flipped.clause == "\"count\" < ?")
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func translatesBooleanLogic() throws {
        let translator = try Self.noteTranslator()

        let direct = try translator.translateWhere(#Predicate<Note> { $0.done })
        #expect(direct.clause == "\"done\" = 1")

        let negated = try translator.translateWhere(#Predicate<Note> { !$0.done })
        #expect(negated.clause == "NOT (\"done\" = 1)")

        let conjunction = try translator.translateWhere(#Predicate<Note> { $0.done && $0.count > 2 })
        #expect(conjunction.clause == "(\"done\" = 1 AND \"count\" > ?)")

        let disjunction = try translator.translateWhere(#Predicate<Note> { $0.done || $0.count > 2 })
        #expect(disjunction.clause == "(\"done\" = 1 OR \"count\" > ?)")

        let comparedToLiteral = try translator.translateWhere(#Predicate<Note> { $0.done == true })
        #expect(comparedToLiteral.clause == "\"done\" = ?")
        #expect(comparedToLiteral.bindings[0] as? Int64 == 1)
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func translatesNilChecksOnOptionals() throws {
        let translator = try Self.typeMixTranslator()

        let isNil = try translator.translateWhere(#Predicate<TypeMix> { $0.subtitle == nil })
        #expect(isNil.clause == "\"subtitle\" IS NULL")
        #expect(isNil.bindings.isEmpty)

        let isNotNil = try translator.translateWhere(#Predicate<TypeMix> { $0.subtitle != nil })
        #expect(isNotNil.clause == "\"subtitle\" IS NOT NULL")
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func bindsTypedConstantsUsingColumnRepresentation() throws {
        let translator = try Self.typeMixTranslator()

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let afterDate = try translator.translateWhere(#Predicate<TypeMix> { $0.stamp > date })
        #expect(afterDate.clause == "\"stamp\" > ?")
        #expect(afterDate.bindings[0] as? Double == 1_700_000_000)

        let mood = Mood.stormy
        let moodEqual = try translator.translateWhere(#Predicate<TypeMix> { $0.mood == mood })
        #expect(moodEqual.clause == "\"mood\" = ?")
        #expect(moodEqual.bindings[0] as? String == "stormy")

        let token = UUID()
        let tokenEqual = try translator.translateWhere(#Predicate<TypeMix> { $0.token == token })
        #expect(tokenEqual.clause == "\"token\" = ?")
        #expect(tokenEqual.bindings[0] as? String == token.uuidString.lowercased())
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func translatesCollectionAndRangeMembership() throws {
        let translator = try Self.noteTranslator()

        let values = [1, 2, 3]
        let inList = try translator.translateWhere(#Predicate<Note> { values.contains($0.count) })
        #expect(inList.clause == "\"count\" IN (?, ?, ?)")
        #expect(inList.bindings.compactMap { $0 as? Int64 } == [1, 2, 3])

        let closed = 1 ... 5
        let between = try translator.translateWhere(#Predicate<Note> { closed.contains($0.count) })
        #expect(between.clause == "\"count\" BETWEEN ? AND ?")

        let halfOpen = 1 ..< 5
        let range = try translator.translateWhere(#Predicate<Note> { halfOpen.contains($0.count) })
        #expect(range.clause == "(\"count\" >= ? AND \"count\" < ?)")
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func translatesStringOperators() throws {
        let translator = try Self.noteTranslator()

        let prefix = try translator.translateWhere(#Predicate<Note> { $0.title.starts(with: "ho") })
        #expect(prefix.clause == "\"title\" LIKE ? ESCAPE '\\'")
        #expect(prefix.bindings[0] as? String == "ho%")

        let contains = try translator.translateWhere(#Predicate<Note> { $0.title.contains("100%") })
        #expect(contains.clause == "\"title\" LIKE ? ESCAPE '\\'")
        #expect(contains.bindings[0] as? String == "%100\\%%")
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func unsupportedNodesPreferInMemoryFiltering() throws {
        let translator = try Self.noteTranslator()

        #expect(throws: DataStoreError.preferInMemoryFilter) {
            _ = try translator.translateWhere(
                #Predicate<Note> { $0.title.localizedStandardContains("hola") }
            )
        }
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func translatesSortDescriptors() throws {
        let translator = try Self.noteTranslator()

        let numeric = try translator.translateOrderBy([SortDescriptor(\Note.count, order: .reverse)])
        #expect(numeric == "\"count\" DESC")

        let mixed = try translator.translateOrderBy([
            SortDescriptor(\Note.title),
            SortDescriptor(\Note.count, order: .reverse),
        ])
        #expect(mixed == "\"title\" COLLATE NOCASE ASC, \"count\" DESC")
    }

    // MARK: integration through ModelContext

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    private static func seededContainer(
        name: String,
        database: any PowerSyncDatabaseProtocol
    ) throws -> ModelContainer {
        let configuration = PowerSyncDataStoreConfiguration(name: name, database: database)
        return try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func filteredSortedFetchThroughModelContext() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let container = try Self.seededContainer(name: "predicates-fetch", database: database)

        let context = ModelContext(container)
        for (index, title) in ["alfa", "bravo", "carlos", "delta"].enumerated() {
            context.insert(Note(id: "n\(index)", title: title, done: index % 2 == 0, count: index))
        }
        try context.save()

        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.count >= 1 },
            sortBy: [SortDescriptor(\.count, order: .reverse)]
        )
        let reader = ModelContext(container)
        let filtered = try reader.fetch(descriptor)
        #expect(filtered.map(\.title) == ["delta", "carlos", "bravo"])

        descriptor.fetchLimit = 2
        descriptor.fetchOffset = 1
        let page = try reader.fetch(descriptor)
        #expect(page.map(\.title) == ["carlos", "bravo"])

        // An untranslatable predicate must still produce correct results through
        // SwiftData's in-memory fallback.
        let fallback = try reader.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.title.localizedStandardContains("AR") }
        ))
        #expect(Set(fallback.map(\.title)) == ["carlos"])

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func fetchCountAndIdentifiersUseSQL() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let container = try Self.seededContainer(name: "predicates-count", database: database)

        let context = ModelContext(container)
        for index in 0 ..< 5 {
            context.insert(Note(id: "n\(index)", title: "t\(index)", done: index % 2 == 0, count: index))
        }
        try context.save()

        let reader = ModelContext(container)
        let count = try reader.fetchCount(FetchDescriptor<Note>(predicate: #Predicate { $0.count >= 2 }))
        #expect(count == 3)

        let identifiers = try reader.fetchIdentifiers(FetchDescriptor<Note>(
            predicate: #Predicate { $0.done }
        ))
        #expect(identifiers.count == 3)
        #expect(Set(identifiers.map(\.entityName)) == ["Note"])

        try await database.close()
    }
}
