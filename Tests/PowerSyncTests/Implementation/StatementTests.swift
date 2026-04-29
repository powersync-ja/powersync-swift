import Foundation
@testable import PowerSync
import Testing

struct StatementTests {
    @Test func bindValues() throws {
        let connection = try DatabaseLocation.inMemory.openConnection(writer: true)
        let lease = connection.asLease()
        try lease.withIterator(
            sql: "SELECT ?, ?, ?, ?, ?, ?, typeof(?), typeof(?)",
            parameters: [
                nil,
                .bool(false),
                .int32(32),
                .int64(64),
                .double(3.14),
                .string("hello"),
                .data(Data()),
                .data(Data([1, 2, 3]))
            ],
            callback: { iterator in
                var hadRow = false
                try iterator.next { cursor in
                    hadRow = true
                    
                    try #require(cursor.getStringOptional(index: 0) == nil)
                    try #require(cursor.getBoolean(index: 1) == false)
                    try #require(cursor.getInt(index: 2) == 32)
                    try #require(cursor.getInt(index: 3) == 64)
                    try #require(cursor.getDouble(index: 4) == 3.14)
                    try #require(cursor.getString(index: 5) == "hello")
                    try #require(cursor.getString(index: 6) == "blob")
                    try #require(cursor.getString(index: 7) == "blob")
                }

                try #require(hadRow)
            }
        )
    }
}
