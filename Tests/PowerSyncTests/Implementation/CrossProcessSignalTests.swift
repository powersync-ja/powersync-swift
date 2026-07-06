import Foundation
@testable import PowerSync
import Testing

/// Changes made by another process must wake `watch` queries.
///
/// PowerSync's update hooks are per-pool: a write that goes through a different pool
/// (another process — an app's widget or App Intent extension) never reaches this pool's
/// `tableUpdates`, so `watch` (and everything built on it: the SwiftData change observer,
/// the upload trigger) was structurally blind to it. A cross-process Darwin notification
/// posted after every committed write closes the gap.
///
/// Two `PowerSyncDatabase` instances over the same file inside one test process use two
/// independent pools, reproducing byte-for-byte the blindness two processes exhibit.
@Suite("Cross-process change signal")
struct CrossProcessSignalTests {
    private static func makeDatabase(path: String) -> any PowerSyncDatabaseProtocol {
        PowerSyncDatabase(
            schema: Schema(tables: [Table(name: "item", columns: [.text("title")])]),
            dbFilename: path,
            logger: DefaultLogger(minSeverity: .warning)
        )
    }

    @available(iOS 16, macOS 13, watchOS 9, tvOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func watchWakesUpForWritesFromAnotherPool() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cross-signal-\(UUID().uuidString).db").path

        let observerSide = Self.makeDatabase(path: path)
        let writerSide = Self.makeDatabase(path: path)

        // Collect watch emissions on the observer side.
        let counts = try observerSide.watch(
            sql: "SELECT COUNT(*) FROM item",
            parameters: []
        ) { try $0.getInt(index: 0) }
        var iterator = counts.makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == [0])

        // A write through the OTHER pool: same file, different update hooks.
        _ = try await writerSide.execute(
            sql: "INSERT INTO item (id, title) VALUES (uuid(), ?)",
            parameters: ["externa"]
        )

        // Without the cross-process signal this hangs until the time limit.
        let afterExternalWrite = try await iterator.next()
        #expect(afterExternalWrite == [1])

        try await observerSide.close()
        try await writerSide.close(deleteDatabase: true)
    }

    @available(iOS 16, macOS 13, watchOS 9, tvOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func externalChangeMarkerMatchesEveryWatchedTable() async throws {
        // The marker says "unknown tables changed"; a watch over any table must re-query.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cross-signal-marker-\(UUID().uuidString).db").path

        let observerSide = Self.makeDatabase(path: path)
        let writerSide = Self.makeDatabase(path: path)

        // Two watches over different shapes (table scan and aggregate) both wake up.
        let titles = try observerSide.watch(
            sql: "SELECT title FROM item ORDER BY title",
            parameters: []
        ) { try $0.getString(index: 0) }
        var titlesIterator = titles.makeAsyncIterator()
        _ = try await titlesIterator.next()

        _ = try await writerSide.execute(
            sql: "INSERT INTO item (id, title) VALUES (uuid(), ?)",
            parameters: ["uno"]
        )
        #expect(try await titlesIterator.next() == [["uno"]].first)

        try await observerSide.close()
        try await writerSide.close(deleteDatabase: true)
    }
}
