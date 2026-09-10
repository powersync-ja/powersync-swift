import Foundation
@testable import PowerSync
import Testing

struct AbsolutePathTests {
    /// An absolute `dbFilename` opens the database at that exact path (creating parent
    /// directories), persists across instances, and `close(deleteDatabase:)` removes the
    /// files there. This is what app extensions need to share a database through an App
    /// Group container.
    @Test func opensPersistsAndDeletesAtAbsolutePath() async throws {
        let schema = Schema(tables: [
            Table(name: "items", columns: [.text("name")]),
        ])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("powersync-absolute-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("nested/shared.db").path

        let database = PowerSyncDatabase(schema: schema, dbFilename: path, logger: DefaultLogger())
        try await database.disconnectAndClear()
        _ = try await database.execute(
            sql: "INSERT INTO items (id, name) VALUES (?, ?)",
            parameters: ["i1", "shared"]
        )
        #expect(FileManager.default.fileExists(atPath: path))
        try await database.close()

        // A second instance over the same absolute path sees the data.
        let reopened = PowerSyncDatabase(schema: schema, dbFilename: path, logger: DefaultLogger())
        let name = try await reopened.get(sql: "SELECT name FROM items WHERE id = ?", parameters: ["i1"]) {
            try $0.getString(index: 0)
        }
        #expect(name == "shared")

        try await reopened.close(deleteDatabase: true)
        #expect(!FileManager.default.fileExists(atPath: path))

        try? FileManager.default.removeItem(at: directory)
    }

    @Test func repeatedAbsolutePathCloseStopsUpdateReaders() async throws {
        let schema = Schema(tables: [
            Table(name: "items", columns: [.text("name")]),
        ])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("powersync-absolute-close-\(UUID().uuidString)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<4 {
                group.addTask {
                    for iteration in 0..<50 {
                        let path = directory
                            .appendingPathComponent("\(lane)-\(iteration).db")
                            .path
                        let database = PowerSyncDatabase(
                            schema: schema,
                            dbFilename: path,
                            logger: DefaultLogger()
                        )
                        _ = try await database.get(sql: "SELECT 1", parameters: nil) { row in
                            try row.getInt(index: 0)
                        }
                        try await database.close(deleteDatabase: true)
                    }
                }
            }
            try await group.waitForAll()
        }

        try? FileManager.default.removeItem(at: directory)
    }
}
