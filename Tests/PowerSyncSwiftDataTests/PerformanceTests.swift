import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Lightweight model for date-window benchmarks.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Entry {
    var id: String
    var stamp: Date
    var value: Double

    init(id: String, stamp: Date, value: Double) {
        self.id = id
        self.stamp = stamp
        self.value = value
    }
}

/// Store-level concurrency stress and date-window benchmarks with generous regression
/// ceilings.
@Suite("Performance and stress")
struct PerformanceTests {
    // MARK: concurrency stress

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(1)))
    func concurrentContextsSaveAndFetchWithoutCorruption() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "performance-stress", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )

        let workers = 16
        let perWorker = 5
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let context = ModelContext(container)
            for index in 0 ..< perWorker {
                context.insert(Note(
                    id: "w\(worker)-\(index)",
                    title: "worker \(worker)",
                    done: index % 2 == 0,
                    count: index
                ))
            }
            do {
                try context.save()
                _ = try context.fetch(FetchDescriptor<Note>())
            } catch {
                Issue.record("worker \(worker) failed: \(error)")
            }
        }

        let reader = ModelContext(container)
        let total = try reader.fetchCount(FetchDescriptor<Note>())
        #expect(total == workers * perWorker)

        try await database.close()
    }

    // MARK: benchmarks

    /// Date-window benchmarks over a 1,000,000-row table (1,000 rows/day x 1,000 days).
    ///
    /// The dataset is seeded like a sync download — straight into `ps_data__entry` with a
    /// recursive CTE — because routing a million models through `ModelContext` would
    /// benchmark SwiftData's context bookkeeping, flood `ps_crud`, and exhaust memory. The
    /// write path is benchmarked separately with a 10k-insert batch save on top of the
    /// loaded table. macOS-only: simulators (especially watchOS) are not a meaningful
    /// performance environment for a million-row dataset.
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(5)), .enabled(if: ProcessInfo.isMacOS))
    func dateWindowBenchmarksAtOneMillionRows() async throws {
        let database = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [
                Table(
                    name: "entry",
                    columns: [.real("stamp"), .real("value")],
                    indexes: [.ascending(name: "stamp", column: "stamp")]
                ),
            ]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        let container = try ModelContainer(
            for: SwiftData.Schema([Entry.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "performance-bench", database: database)]
        )

        // 1,000 rows per day across 1,000 days, each day's rows spread inside the day:
        // for row i, day = i % 1000 and the in-day offset is (i / 1000) * 86.4 seconds,
        // so every window count below is exact.
        let totalRows = 1_000_000
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let day: TimeInterval = 86_400
        let clock = ContinuousClock()

        let seedTime = try await clock.measure {
            _ = try await database.execute(
                sql: """
                WITH RECURSIVE seq(i) AS (
                    SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < \(totalRows - 1)
                )
                INSERT INTO ps_data__entry (id, data)
                SELECT 'e' || i, json_object(
                    'stamp', \(now.timeIntervalSince1970) - (i % 1000) * 86400.0 - (i / 1000) * 86.4,
                    'value', i * 1.0
                )
                FROM seq
                """,
                parameters: []
            )
        }
        let total = try await database.get(sql: "SELECT COUNT(*) FROM entry", parameters: []) {
            try $0.getInt(index: 0)
        }
        #expect(total == totalRows)

        let reader = ModelContext(container)

        // 28-day count: pure SQL through the translated predicate.
        let window28Start = now.addingTimeInterval(-28 * day)
        var window28 = 0
        let countTime = try clock.measure {
            window28 = try reader.fetchCount(FetchDescriptor<Entry>(
                predicate: #Predicate { $0.stamp > window28Start }
            ))
        }
        #expect(window28 == 28 * 1000)

        // 60-day window, sorted, first page of 200: the typical UI query.
        let window60Start = now.addingTimeInterval(-60 * day)
        var pageDescriptor = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.stamp > window60Start },
            sortBy: [SortDescriptor(\.stamp, order: .reverse)]
        )
        pageDescriptor.fetchLimit = 200
        var page: [Entry] = []
        let pageTime = try clock.measure {
            page = try reader.fetch(pageDescriptor)
        }
        #expect(page.count == 200)
        #expect(abs(page[0].stamp.timeIntervalSince(now)) < day)

        // Full 60-day window materialized (60,000 models): the heavy honest case.
        var window60 = 0
        let windowTime = try clock.measure {
            window60 = try reader.fetch(FetchDescriptor<Entry>(
                predicate: #Predicate { $0.stamp > window60Start },
                sortBy: [SortDescriptor(\.stamp, order: .reverse)]
            )).count
        }
        #expect(window60 == 60 * 1000)

        // Write path on top of the loaded table: 10k inserts in one batch save.
        let writer = ModelContext(container)
        let insertTime = try clock.measure {
            for index in 0 ..< 10_000 {
                writer.insert(Entry(
                    id: "new-\(index)",
                    stamp: now.addingTimeInterval(Double(index)),
                    value: Double(index)
                ))
            }
            try writer.save()
        }

        print("""
        [bench 1M] seed: \(seedTime); 28-day count: \(countTime); \
        60-day page(200): \(pageTime); 60-day full fetch (60k models): \(windowTime); \
        10k-insert save: \(insertTime)
        """)

        // Generous ceilings: these catch pathological regressions, not micro-variance.
        #expect(seedTime < .seconds(30))
        #expect(countTime < .seconds(1))
        #expect(pageTime < .seconds(1))
        #expect(windowTime < .seconds(10))
        #expect(insertTime < .seconds(10))

        try await database.close()
    }
}

extension ProcessInfo {
    /// Benchmarks at million-row scale only run on macOS hosts, not simulators.
    static var isMacOS: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}
