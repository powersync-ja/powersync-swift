import Foundation
@testable import PowerSync
import Testing

/// Cross-process changes wake only the watches whose tables actually changed.
///
/// Each write records the precise tables it touched in `ps_swift_updates`; a receiver reads
/// the new rows (ignoring its own `author`) and re-emits exactly those tables. So a write to
/// one table in another process does not re-run watches over unrelated tables, which is what
/// removes the re-query amplification that a catch-all cross-process marker caused.
///
/// Two `PowerSyncDatabase` instances over the same file inside one test process use two
/// independent pools with distinct authors, reproducing what two processes do.
@Suite("Cross-process precise propagation")
struct CrossProcessPreciseTests {
    private static func makeDatabase(path: String) -> any PowerSyncDatabaseProtocol {
        PowerSyncDatabase(
            schema: Schema(tables: [
                Table(name: "a", columns: [.text("v")]),
                Table(name: "b", columns: [.text("v")]),
            ]),
            dbFilename: path,
            logger: DefaultLogger(minSeverity: .warning)
        )
    }

    @Test
    func aWriteToAnotherTableDoesNotWakeAnUnrelatedWatch() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("xchg-precise-\(UUID().uuidString).db").path

        let observerSide = Self.makeDatabase(path: path)
        let writerSide = Self.makeDatabase(path: path)

        // Observer watches table "a" only.
        let countsA = try observerSide.watch(
            sql: "SELECT COUNT(*) FROM a",
            parameters: []
        ) { try $0.getInt(index: 0) }
        var iterator = countsA.makeAsyncIterator()
        #expect(try await iterator.next() == [0])

        // A write to "b" in the other process must not wake the watch over "a". Give the
        // coalesced cross-process read time to run and (correctly) emit nothing for "a".
        _ = try await writerSide.execute(sql: "INSERT INTO b (id, v) VALUES (uuid(), ?)", parameters: ["x"])
        // Comfortably longer than the 250ms coalescing window, so a loaded CI machine still
        // finishes the cross-process read for this write before the next one is made.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // A write to "a" in the other process wakes it, and the next emission is the count
        // after that write. If the "b" write had amplified into a re-query, the next emission
        // would instead be a stale [0] from before.
        _ = try await writerSide.execute(sql: "INSERT INTO a (id, v) VALUES (uuid(), ?)", parameters: ["y"])
        #expect(try await iterator.next() == [1])

        try await observerSide.close()
        try await writerSide.close(deleteDatabase: true)
    }

    /// A process must not announce its own writes twice: they are dispatched locally when the
    /// write commits, and the notification it receives back for them must find nothing, since
    /// rows are read with `author != self`. Without that filter every write would be announced a
    /// second time, which is what fed the re-query loop.
    ///
    /// Counting on `tableUpdates` rather than through `watch`, because a watch query coalesces
    /// two updates arriving close together into a single re-run and would hide the difference.
    @Test
    func ownWriteIsAnnouncedOnlyOnce() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("xchg-self-\(UUID().uuidString).db").path
        let db = Self.makeDatabase(path: path)
        let pool = try #require(db as? PowerSyncDatabaseImpl).pool

        // Make sure the database is open (and the listener armed) before counting.
        _ = try await db.get(sql: "SELECT 1", parameters: []) { try $0.getInt(index: 0) }

        let announcements = Announcements()
        let updates = pool.tableUpdates
        let collector = Task {
            for await tables in updates where tables.contains("ps_data__a") {
                announcements.increment()
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        _ = try await db.execute(sql: "INSERT INTO a (id, v) VALUES (uuid(), ?)", parameters: ["x"])
        // Longer than the coalescing window, so a self-delivered notification would have been
        // read and re-announced by now if it were not filtered out by author.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        #expect(announcements.value == 1, "our own write must be announced exactly once")

        collector.cancel()
        try await db.close(deleteDatabase: true)
    }
}

/// Only changes another process can act on are worth recording and signalling.
@Suite("Cross-process table relevance")
struct CrossProcessRelevanceTests {
    @Test
    func onlyUserDataAndCrudPropagate() {
        // `ps_` is reserved for PowerSync, so anything else is a user or raw table.
        #expect(CrossProcessUpdateLog.isRelevant("todos"))
        #expect(CrossProcessUpdateLog.isRelevant("my_raw_table"))

        // User data managed by PowerSync: `watch` queries read these.
        #expect(CrossProcessUpdateLog.isRelevant("ps_data__todos"))
        #expect(CrossProcessUpdateLog.isRelevant("ps_data_local__attachments"))

        // The upload client wakes on `ps_crud`.
        #expect(CrossProcessUpdateLog.isRelevant("ps_crud"))

        // Internal bookkeeping has no cross-process consumer.
        #expect(!CrossProcessUpdateLog.isRelevant("ps_buckets"))
        #expect(!CrossProcessUpdateLog.isRelevant("ps_oplog"))
        #expect(!CrossProcessUpdateLog.isRelevant("ps_tx"))
        #expect(!CrossProcessUpdateLog.isRelevant("ps_stream_subscriptions"))
        #expect(!CrossProcessUpdateLog.isRelevant("ps_sync_state"))
        #expect(!CrossProcessUpdateLog.isRelevant(CrossProcessUpdateLog.tableName))
    }
}

/// Thread-safe counter for table updates observed from a collecting task.
private final class Announcements: @unchecked Sendable {
    private let lock = Mutex(0)
    var value: Int { lock.withLock { $0 } }
    func increment() { lock.withLock { $0 += 1 } }
}
