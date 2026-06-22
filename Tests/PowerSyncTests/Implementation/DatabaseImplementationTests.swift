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
}
