@testable import PowerSync
import XCTest

final class CrudTests: XCTestCase {
    private var database: (any PowerSyncDatabaseProtocol)!
    private var schema: Schema!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(
                name: "users",
                columns: [
                    .text("name"),
                    .text("email"),
                    .integer("favorite_number"),
                    .text("photo_id"),
                ]
            ),
        ])

        database = KotlinPowerSyncDatabaseImpl(
            schema: schema,
            dbFilename: ":memory:",
            logger: DatabaseLogger(DefaultLogger())
        )
        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try await database.disconnectAndClear()
        try await database.close()
        database = nil
        try await super.tearDown()
    }

    func testCrudBatch() async throws {
        // Create some items
        try await database.writeTransaction { tx in
            for i in 0 ..< 100 {
                try tx.execute(
                    sql: "INSERT INTO users (id, name, email, favorite_number) VALUES (uuid(), 'a', 'a@example.com', ?)",
                    parameters: [i]
                )
            }
        }

        // Get a limited set of batched operations
        guard let limitedBatch = try await database.getCrudBatch(limit: 50) else {
            return XCTFail("Failed to get crud batch")
        }
        
        guard let crudItem = limitedBatch.crud.first else {
            return XCTFail("Crud batch should contain crud entries")
        }
        
        // This should show as a string even though it's a number
        // This is what the typing conveys
        let opData = crudItem.opData?["favorite_number"]
        XCTAssert(opData == "0")

        XCTAssert(limitedBatch.hasMore == true)
        XCTAssert(limitedBatch.crud.count == 50)
        
        guard let fullBatch = try await database.getCrudBatch() else {
            return XCTFail("Failed to get crud batch")
        }
        
        XCTAssert(fullBatch.hasMore == false)
        XCTAssert(fullBatch.crud.count == 100)
        
        guard let txBatch = try await database.getNextCrudTransaction() else {
            return XCTFail("Failed to get transaction crud batch")
        }
        
        XCTAssert(txBatch.crud.count == 100)
        
        // Completing the transaction should clear the items
        try await txBatch.complete()
        
        let afterCompleteBatch = try await database.getNextCrudTransaction()
        XCTAssertNil(afterCompleteBatch)
    }
}
