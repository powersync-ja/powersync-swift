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

        database = openKotlinDBDefault(
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

    func testTrackMetadata() async throws {
        try await database.updateSchema(schema: Schema(tables: [
            Table(name: "lists", columns: [.text("name")], trackMetadata: true)
        ]))

        try await database.execute("INSERT INTO lists (id, name, _metadata) VALUES (uuid(), 'test', 'so meta')")
        guard let batch = try await database.getNextCrudTransaction() else {
            return XCTFail("Should have batch after insert")
        }

        XCTAssertEqual(batch.crud[0].metadata, "so meta")
    }

    func testTrackPreviousValues() async throws {
        try await database.updateSchema(schema: Schema(tables: [
            Table(
                name: "lists",
                columns: [.text("name"), .text("content")],
                trackPreviousValues: TrackPreviousValuesOptions()
            )
        ]))

        try await database.execute("INSERT INTO lists (id, name, content) VALUES (uuid(), 'entry', 'content')")
        try await database.execute("DELETE FROM ps_crud")
        try await database.execute("UPDATE lists SET name = 'new name'")

        guard let batch = try await database.getNextCrudTransaction() else {
            return XCTFail("Should have batch after update")
        }

        XCTAssertEqual(batch.crud[0].previousValues, ["name": "entry", "content": "content"])
    }

    func testTrackPreviousValuesWithFilter() async throws {
        try await database.updateSchema(schema: Schema(tables: [
            Table(
                name: "lists",
                columns: [.text("name"), .text("content")],
                trackPreviousValues: TrackPreviousValuesOptions(
                    columnFilter: ["name"]
                )
            )
        ]))

        try await database.execute("INSERT INTO lists (id, name, content) VALUES (uuid(), 'entry', 'content')")
        try await database.execute("DELETE FROM ps_crud")
        try await database.execute("UPDATE lists SET name = 'new name'")

        guard let batch = try await database.getNextCrudTransaction() else {
            return XCTFail("Should have batch after update")
        }

        XCTAssertEqual(batch.crud[0].previousValues, ["name": "entry"])
    }

    func testTrackPreviousValuesOnlyWhenChanged() async throws {
        try await database.updateSchema(schema: Schema(tables: [
            Table(
                name: "lists",
                columns: [.text("name"), .text("content")],
                trackPreviousValues: TrackPreviousValuesOptions(
                    onlyWhenChanged: true
                )
            )
        ]))

        try await database.execute("INSERT INTO lists (id, name, content) VALUES (uuid(), 'entry', 'content')")
        try await database.execute("DELETE FROM ps_crud")
        try await database.execute("UPDATE lists SET name = 'new name'")

        guard let batch = try await database.getNextCrudTransaction() else {
            return XCTFail("Should have batch after update")
        }

        XCTAssertEqual(batch.crud[0].previousValues, ["name": "entry"])
    }

    func testIgnoreEmptyUpdate() async throws {
        try await database.updateSchema(schema: Schema(tables: [
            Table(name: "lists", columns: [.text("name")], ignoreEmptyUpdates: true)
        ]))
        try await database.execute("INSERT INTO lists (id, name) VALUES (uuid(), 'test')")
        try await database.execute("DELETE FROM ps_crud")
        try await database.execute("UPDATE lists SET name = 'test'") // Same value!

        let batch = try await database.getNextCrudTransaction()
        XCTAssertNil(batch)
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

        guard let nextTx = try await database.getNextCrudTransaction() else {
            return XCTFail("Failed to get transaction crud batch")
        }

        XCTAssert(nextTx.crud.count == 100)

        for r in nextTx.crud {
            print(r)
        }

        // Completing the transaction should clear the items
        try await nextTx.complete()

        let afterCompleteBatch = try await database.getNextCrudTransaction()

        for r in afterCompleteBatch?.crud ?? [] {
            print(r)
        }

        XCTAssertNil(afterCompleteBatch)

        try await database.writeTransaction { tx in
            for i in 0 ..< 100 {
                try tx.execute(
                    sql: "INSERT INTO users (id, name, email, favorite_number) VALUES (uuid(), 'a', 'a@example.com', ?)",
                    parameters: [i]
                )
            }
        }

        guard let finalBatch = try await database.getCrudBatch(limit: 100) else {
            return XCTFail("Failed to get crud batch")
        }
        XCTAssert(finalBatch.crud.count == 100)
        XCTAssert(finalBatch.hasMore == false)
        // Calling complete without a writeCheckpoint param should be possible
        try await finalBatch.complete()

        let finalValidationBatch = try await database.getCrudBatch(limit: 100)
        XCTAssertNil(finalValidationBatch)
    }

    func testCrudTransactions() async throws {
        func insertInTransaction(size: Int) async throws {
            try await database.writeTransaction { tx in
                for _ in 0 ..< size {
                    try tx.execute(
                        sql: "INSERT INTO users (id, name, email) VALUES (uuid(), null, null)",
                        parameters: []
                    )
                }
            }
        }

        // Before inserting any data, the iterator should be empty.
        for try await _ in database.getCrudTransactions() {
            XCTFail("Unexpected transaction")
        }

        try await insertInTransaction(size: 5)
        try await insertInTransaction(size: 10)
        try await insertInTransaction(size: 15)

        var batch = [CrudEntry]()
        var lastTx: CrudTransaction? = nil
        for try await tx in database.getCrudTransactions() {
            batch.append(contentsOf: tx.crud)
            lastTx = tx

            if batch.count >= 10 {
                break
            }
        }

        XCTAssertEqual(batch.count, 15)
        try await lastTx!.complete()

        let finalTx = try await database.getNextCrudTransaction()
        XCTAssertEqual(finalTx!.crud.count, 15)
    }
}
