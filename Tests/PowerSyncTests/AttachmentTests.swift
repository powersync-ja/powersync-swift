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
            createAttachmentTable(name: "attachments")
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

    func getAttachmentDirectory() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("attachments").path
    }

    func testAttachmentDownload() async throws {
        let queue = AttachmentQueue(
            db: database,
            remoteStorage: {
                struct MockRemoteStorage: RemoteStorageAdapter {
                    func uploadFile(
                        fileData _: Data,
                        attachment _: Attachment
                    ) async throws {}

                    /**
                     * Download a file from remote storage
                     */
                    func downloadFile(attachment _: Attachment) async throws -> Data {
                        return Data([1, 2, 3])
                    }

                    /**
                     * Delete a file from remote storage
                     */
                    func deleteFile(attachment _: Attachment) async throws {}
                }

                return MockRemoteStorage()
            }(),
            attachmentsDirectory: getAttachmentDirectory(),
            watchAttachments: { [database = database!] in
                try database.watch(options: WatchOptions(
                    sql: "SELECT photo_id FROM users WHERE photo_id IS NOT  NULL",
                    mapper: { cursor in try WatchedAttachmentItem(
                        id: cursor.getString(name: "photo_id"),
                        fileExtension: "jpg"
                    ) }
                ))
            }
        )

        try await queue.startSync()

        // Create a user which has a photo_id associated.
        // This will be treated as a download since no attachment record was created.
        // saveFile creates the attachment record before the updates are made.
        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email, photo_id) VALUES (uuid(), 'steven', 'steven@example.com', uuid())",
            parameters: []
        )

        let attachmentRecord = try await waitForMatch(
            iteratorGenerator: { [database = database!] in try database.watch(
                options: WatchOptions(
                    sql: "SELECT * FROM attachments",
                    mapper: { cursor in try Attachment.fromCursor(cursor) }
                )) },
            where: { results in results.first?.state == AttachmentState.synced },
            timeout: 5
        ).first

//         The file should exist
        let localData = try await queue.localStorage.readFile(filePath: attachmentRecord!.localUri!)
        XCTAssertEqual(localData.count, 3)

        try await queue.clearQueue()
        try await queue.close()
    }

    func testAttachmentUpload() async throws {
        actor MockRemoteStorage: RemoteStorageAdapter {
            public var uploadCalled = false

            func wasUploadCalled() -> Bool {
                return uploadCalled
            }

            func uploadFile(
                fileData _: Data,
                attachment _: Attachment
            ) async throws {
                uploadCalled = true
            }

            /**
             * Download a file from remote storage
             */
            func downloadFile(attachment _: Attachment) async throws -> Data {
                return Data([1, 2, 3])
            }

            /**
             * Delete a file from remote storage
             */
            func deleteFile(attachment _: Attachment) async throws {}
        }

        let mockedRemote = MockRemoteStorage()

        let queue = AttachmentQueue(
            db: database,
            remoteStorage: mockedRemote,
            attachmentsDirectory: getAttachmentDirectory(),
            watchAttachments: { [database = database!] in try database.watch(options: WatchOptions(
                sql: "SELECT photo_id FROM users WHERE photo_id IS NOT  NULL",
                mapper: { cursor in try WatchedAttachmentItem(
                    id: cursor.getString(name: "photo_id"),
                    fileExtension: "jpg"
                ) }
            )) }
        )

        try await queue.startSync()

        _ = try await queue.saveFile(
            data: Data([3, 4, 5]),
            mediaType: "image/jpg",
            fileExtension: "jpg"
        ) { transaction, attachment in
            _ = try transaction.execute(
                sql: "INSERT INTO users (id, name, email, photo_id) VALUES (uuid(), 'john', 'j@j.com', ?)",
                parameters: [attachment.id]
            )
        }

        _ = try await waitForMatch(
            iteratorGenerator: { [database = database!] in
                try database.watch(
                    options: WatchOptions(
                        sql: "SELECT * FROM attachments",
                        mapper: { cursor in try Attachment.fromCursor(cursor) }
                    ))
            },
            where: { results in results.first?.state == AttachmentState.synced },
            timeout: 5
        ).first

        let uploadCalled = await mockedRemote.wasUploadCalled()
        // Upload should have been called
        XCTAssertTrue(uploadCalled)

        try await queue.clearQueue()
        try await queue.close()
    }

    func testAttachmentInitVerification() async throws {
        actor MockRemoteStorage: RemoteStorageAdapter {
            func uploadFile(
                fileData _: Data,
                attachment _: Attachment
            ) async throws {}

            func downloadFile(attachment _: Attachment) async throws -> Data {
                return Data([1, 2, 3])
            }

            func deleteFile(attachment _: Attachment) async throws {}
        }

        // Create an attachments record which has an invalid local_uri
        let attachmentsDirectory = getAttachmentDirectory()

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: attachmentsDirectory),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let filename = "test.jpeg"

        try Data("1".utf8).write(
            to: URL(fileURLWithPath: attachmentsDirectory).appendingPathComponent(filename)
        )
        try await database.execute(
            sql: """
            INSERT OR REPLACE INTO 
                attachments (id, timestamp, filename, local_uri, media_type, size, state, has_synced, meta_data) 
            VALUES
                (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                Date().ISO8601Format(),
                filename,
                // This is a broken local_uri
                URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("not_attachments/test.jpeg").path,
                "application/jpeg",
                1,
                AttachmentState.synced.rawValue,
                1,
                ""
            ]
        )

        let mockedRemote = MockRemoteStorage()

        let queue = AttachmentQueue(
            db: database,
            remoteStorage: mockedRemote,
            attachmentsDirectory: attachmentsDirectory,
            watchAttachments: { [database = database!] in try database.watch(options: WatchOptions(
                sql: "SELECT photo_id FROM users WHERE photo_id IS NOT  NULL",
                mapper: { cursor in try WatchedAttachmentItem(
                    id: cursor.getString(name: "photo_id"),
                    fileExtension: "jpg"
                ) }
            )) }
        )

        try await queue.waitForInit()

        // the attachment should have been corrected in the init
        let attachments = try await queue.attachmentsService.withContext { context in
            try await context.getAttachments()
        }

        guard let firstAttachment = attachments.first else {
            XCTFail("Could not find the attachment record")
            return
        }

        XCTAssert(firstAttachment.localUri == URL(fileURLWithPath: attachmentsDirectory).appendingPathComponent(filename).path)
    }
}

public enum WaitForMatchError: Error {
    case timeout(lastError: Error? = nil)
    case predicateFail(message: String)
}

public func waitForMatch<T: Sendable, E: Error>(
    iteratorGenerator: @Sendable @escaping () throws -> AsyncThrowingStream<T, E>,
    where predicate: @Sendable @escaping (T) -> Bool,
    timeout: TimeInterval
) async throws -> T {
    let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)

    return try await withThrowingTaskGroup(of: T.self) { group in
        // Task to wait for a matching value
        group.addTask { [iteratorGenerator] in
            for try await value in try iteratorGenerator() where predicate(value) {
                return value
            }
            throw WaitForMatchError.timeout() // stream ended before match
        }

        // Task to enforce timeout
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw WaitForMatchError.timeout()
        }

        // First one to succeed or fail
        let result = try await group.next()
        group.cancelAll()
        return result!
    }
}

func waitFor(
    timeout: TimeInterval = 0.5,
    interval: TimeInterval = 0.1,
    predicate: () async throws -> Void
) async throws {
    let intervalNanoseconds = UInt64(interval * 1_000_000_000)

    let timeoutDate = Date(
        timeIntervalSinceNow: timeout
    )

    var lastError: Error?

    while Date() < timeoutDate {
        do {
            try await predicate()
            return
        } catch {
            lastError = error
        }
        try await Task.sleep(nanoseconds: intervalNanoseconds)
    }

    throw WaitForMatchError.timeout(
        lastError: lastError
    )
}
