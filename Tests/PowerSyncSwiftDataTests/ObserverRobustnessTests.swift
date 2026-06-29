import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Failure modes of the change observer: `start()` must throw (never hang) when a watch
/// cannot prime, the observer must be restartable after failures and after `stop()`, and
/// bursts of remote changes must coalesce instead of queueing full-table emissions.
@Suite("Observer robustness")
struct ObserverRobustnessTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(1)))
    func startThrowsInsteadOfHangingWhenTheTableIsMissing() async throws {
        // A database whose PowerSync schema lacks the note table; the configuration's
        // SwiftData schema is set directly so no container-level validation runs first.
        let database = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [Table(name: "unrelated", columns: [.text("x")])]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        let configuration = PowerSyncDataStoreConfiguration(
            name: "observer-missing-table",
            database: database,
            schema: SwiftData.Schema([Note.self])
        )
        let observerContainer = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let observer = PowerSyncChangeObserver(container: observerContainer, configuration: configuration)
        await #expect(throws: (any Error).self) {
            try await observer.start(observing: [Note.self])
        }

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(1)))
    func observerIsRestartableAfterAFailedStart() async throws {
        // First start fails (missing table); after fixing the schema, a second start on
        // the SAME observer succeeds and reactivity works.
        let database = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [Table(name: "unrelated", columns: [.text("x")])]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        let configuration = PowerSyncDataStoreConfiguration(
            name: "observer-restart",
            database: database,
            schema: SwiftData.Schema([Note.self])
        )
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let observer = PowerSyncChangeObserver(container: container, configuration: configuration)

        await #expect(throws: (any Error).self) {
            try await observer.start(observing: [Note.self])
        }

        try await database.updateSchema(schema: PowerSync.Schema(tables: [
            Table(name: "note", columns: [.text("title"), .integer("done"), .integer("count")]),
        ]))
        try await observer.start(observing: [Note.self])
        await observer.stop()

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(1)))
    func stopThenStartKeepsWorking() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "observer-stopstart", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )
        let observer = PowerSyncChangeObserver(container: container, configuration: configuration)
        try await observer.start(observing: [Note.self])
        await observer.stop()
        try await observer.start(observing: [Note.self])

        // Reactivity still functions after the restart.
        _ = try await database.execute(
            sql: "INSERT INTO ps_data__note (id, data) VALUES (?, json_object('title', 'tras-restart', 'done', 0, 'count', 1))",
            parameters: ["r1"]
        )
        try await Task.sleep(for: .milliseconds(400))
        let fetched = try ModelContext(container).fetch(FetchDescriptor<Note>())
        #expect(fetched.first?.title == "tras-restart")

        await observer.stop()
        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(1)))
    func rapidRemoteBurstsCoalesceAndConverge() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "observer-burst", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )
        let observer = PowerSyncChangeObserver(container: container, configuration: configuration)
        try await observer.start(observing: [Note.self])

        // A burst of remote writes faster than any reconcile cycle.
        for index in 0 ..< 50 {
            _ = try await database.execute(
                sql: "INSERT INTO ps_data__note (id, data) VALUES (?, json_object('title', ?, 'done', 0, 'count', \(index)))",
                parameters: ["burst-\(index)", "n\(index)"]
            )
        }

        // The observer must converge to the final state.
        var converged = false
        for _ in 0 ..< 50 {
            try await Task.sleep(for: .milliseconds(100))
            let count = try ModelContext(container).fetchCount(FetchDescriptor<Note>())
            if count == 50 {
                converged = true
                break
            }
        }
        #expect(converged)

        await observer.stop()
        try await database.close()
    }
}
