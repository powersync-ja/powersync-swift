import Foundation
@testable import PowerSync
import Testing

struct DatabaseImplementationTests {
    @Test func readTransaction() async throws {
        // Regression test for https://github.com/powersync-ja/powersync-swift/issues/142.
        let db = PowerSyncDatabase(
            schema: Schema(),
            dbFilename: "read-tx-regression-test",
            logger: DefaultLogger()
        )

        let description = try await db.readTransaction { tx in
            try tx.get(sql: "SELECT 1", parameters: [], mapper: { cursor in  })
            
            // Writing to the database in a read-only connection must fail.
            let error = #expect(throws: PowerSyncError.self) {
                try tx.execute(sql: "DELETE FROM ps_kv", parameters: [])
            }
            return try #require(error?.errorDescription)
        }
        try await db.close(deleteDatabase: true)
        #expect(description.contains("attempt to write a readonly database"))
    }
    
    @Test func canUseConnectionInCallback() async throws {
        let db = PowerSyncDatabase(
            schema: Schema(),
            dbFilename: ":memory:",
            logger: DefaultLogger()
        )
        
        let results = try await db.readTransaction { tx in
            try tx.getAll(sql: "VALUES (1), (2), (3)", parameters: []) { outerCursor in
                let outerValue = try outerCursor.getInt64(index: 0)
                return try tx.get(sql: "SELECT 2 * ?", parameters: [outerValue]) { innerCursor in
                    try innerCursor.getInt64(index: 0)
                }
            }
        }
        try #require(results == [2, 4, 6])
        try await db.close()
    }

    @Test func canCancelClose() async throws {
        let db = PowerSyncDatabase(
            schema: Schema(),
            dbFilename: "cancel-close-test",
            logger: DefaultLogger()
        )

        let result = try await db.readLock { reader in
            // Try to close the database, this can't work because of the busy read connection.
            let task = Task { try await db.close() };
            task.cancel();
            return task
        }.result
        #expect(throws: CancellationError.self) { try result.get() }

        // Verify that the database is not in a half-closed state by updating the schema, which runs statements
        // on all connections.
        try await db.updateSchema(schema: Schema(Table(name: "users", columns: [.text("name")])))
    }

    @Test func canCloseAfterCancellingClose() async throws {
        let pool = AsyncConnectionPool(
            location: .inMemory,
            logger: DefaultLogger()
        )
        let db = OpenedPowerSyncDatabase(
            schema: Schema(),
            pool: pool,
            identifier: "cancel-then-close-test"
        )

        let (readerAcquired, signalReaderAcquired) = AsyncStream<Void>.makeStream()
        let releaseReader = DispatchSemaphore(value: 0)
        let reader = Task {
            try await db.readLock { _ in
                signalReaderAcquired.yield()
                releaseReader.wait()
            }
        }

        // Wait until the callback has leased a reader, then initiate close independently.
        var readerAcquiredIterator = readerAcquired.makeAsyncIterator()
        _ = await readerAcquiredIterator.next()
        let cancelledClose = Task { try await db.close() }
        cancelledClose.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledClose.value
        }
        releaseReader.signal()
        try await reader.value

        // Retrying close must still reach and close the underlying connection pool.
        try await db.close()

        // We inspect the pool directly because the database's initialization actor now considers
        // the database closed and would reject public operations before they reach the pool. A
        // successful retry closes every RawSqliteConnection, so acquiring a lease must throw. If
        // this succeeds, PoolOpener kept isClosed = true after the cancelled attempt and treated
        // the retry as a no-op, leaving the native connections open.
        await #expect(throws: PowerSyncError.self) {
            try await pool.read { _ in () }
        }
    }
}
