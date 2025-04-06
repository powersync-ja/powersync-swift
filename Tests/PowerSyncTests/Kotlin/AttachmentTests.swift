
@testable import PowerSync
import XCTest

final class AttachmentTests: XCTestCase {
    private var database: PowerSyncDatabaseProtocol!
    private var schema: Schema!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(name: "users", columns: [
                .text("name"),
                .text("email"),
                .text("photo_id")
            ]),
            createAttachmentsTable(name: "attachments")
        ])

        database = PowerSyncDatabase(
            schema: schema,
            dbFilename: ":memory:"
        )
        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try await database.disconnectAndClear()
        database = nil
        try await super.tearDown()
    }

    func testAttachmentDownload() async throws {
        let queue = AttachmentQueue(
            db: database,
            remoteStorage: {
                struct MockRemoteStorage: RemoteStorageAdapter {
                    func uploadFile(
                        fileData: Data,
                        attachment: Attachment
                    ) async throws {}
                    
                    /**
                     * Download a file from remote storage
                     */
                    func downloadFile(attachment: Attachment) async throws -> Data {
                        return Data([1,2,3])
                    }
                    
                    /**
                     * Delete a file from remote storage
                     */
                    func deleteFile(attachment: Attachment) async throws {}
                    
                }
        
                return MockRemoteStorage()
            }(),
            attachmentDirectory: NSTemporaryDirectory(),
            watchedAttachments: try database.watch(options: WatchOptions(
                sql: "SELECT photo_id FROM users WHERE photo_id IS NOT  NULL",
                mapper: { cursor in WatchedAttachmentItem(
                    id: try cursor.getString(name: "photo_id"),
                    fileExtension: "jpg"
                )}
            ))
        )
        
        try await queue.startSync()
        
        // Create a user which has a photo_id associated.
        // This will be treated as a download since no attachment record was created.
        // saveFile creates the attachment record before the updates are made.
        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email, photo_id) VALUES (uuid(), 'steven', 'steven@example.com', uuid())",
            parameters: []
        )
        
        var attachmentsWatch = try database.watch(
            options: WatchOptions(
                sql: "SELECT * FROM attachments",
                mapper: {cursor in try Attachment.fromCursor(cursor)}
            )).makeAsyncIterator()
        
       var attachmentRecord = try await waitForMatch(
            iterator: attachmentsWatch,
            where: {results in results.first?.state == AttachmentState.synced.rawValue},
            timeout: 5
       ).first
        
        // The file should exist
        let localData = try await queue.localStorage.readFile(filePath: attachmentRecord!.localUri!)
        XCTAssertEqual(localData.count, 3)
        
        try await queue.clearQueue()
        try await queue.close()
    }
    
    func testAttachmentUpload() async throws {
        
        class MockRemoteStorage: RemoteStorageAdapter {
            public var uploadCalled = false
            
            func uploadFile(
                fileData: Data,
                attachment: Attachment
            ) async throws {
                self.uploadCalled = true
            }
            
            /**
             * Download a file from remote storage
             */
            func downloadFile(attachment: Attachment) async throws -> Data {
                return Data([1,2,3])
            }
            
            /**
             * Delete a file from remote storage
             */
            func deleteFile(attachment: Attachment) async throws {}
            
        }

        
        
        let mockedRemote = MockRemoteStorage()
        
        let queue = AttachmentQueue(
            db: database,
            remoteStorage: mockedRemote,
            attachmentDirectory: NSTemporaryDirectory(),
            watchedAttachments: try database.watch(options: WatchOptions(
                sql: "SELECT photo_id FROM users WHERE photo_id IS NOT  NULL",
                mapper: { cursor in WatchedAttachmentItem(
                    id: try cursor.getString(name: "photo_id"),
                    fileExtension: "jpg"
                )}
            ))
        )
        
        try await queue.startSync()
        
        let attachmentsWatch = try database.watch(
            options: WatchOptions(
                sql: "SELECT * FROM attachments",
                mapper: {cursor in try Attachment.fromCursor(cursor)}
            )).makeAsyncIterator()
        
        _ = try await queue.saveFile(
            data: Data([3,4,5]),
            mediaType: "image/jpg",
            fileExtension: "jpg") {tx, attachment in
             _ = try tx.execute(
                    sql: "INSERT INTO users (id, name, email, photo_id) VALUES (uuid(), 'john', 'j@j.com', ?)",
                    parameters: [attachment.id]
                )
            }
        
       _  = try await waitForMatch(
            iterator: attachmentsWatch,
            where: {results in results.first?.state == AttachmentState.synced.rawValue},
            timeout: 5
       ).first
        
        // Upload should have been called
        XCTAssertTrue(mockedRemote.uploadCalled)
        
        try await queue.clearQueue()
        try await queue.close()
    }
}


enum WaitForMatchError: Error {
    case timeout
}

func waitForMatch<T, E: Error>(
    iterator: AsyncThrowingStream<T, E>.Iterator,
    where predicate: @escaping (T) -> Bool,
    timeout: TimeInterval
) async throws -> T {
    var localIterator = iterator
    let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)

    return try await withThrowingTaskGroup(of: T.self) { group in
        // Task to wait for a matching value
        group.addTask {
            while let value = try await localIterator.next() {
                if predicate(value) {
                    return value
                }
            }
            throw WaitForMatchError.timeout // stream ended before match
        }

        // Task to enforce timeout
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw WaitForMatchError.timeout
        }

        // First one to succeed or fail
        let result = try await group.next()
        group.cancelAll()
        return result!
    }
}
