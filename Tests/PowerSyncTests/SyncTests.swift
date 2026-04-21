import AsyncAlgorithms
@testable import PowerSync
import Synchronization
import Testing

@Suite()
class InMemorySyncIntegrationTests {
    @Test func setsHeaders() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpClient { request in
            try #require(request.value(forHTTPHeaderField: "User-Agent")!.contains("powersync-swift/"))
            try #require(request.value(forHTTPHeaderField: "Authorization") == "Token test-token")
            await didConnect.complete()
            return AsyncThrowingChannel()
        })
        
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await didConnect.await()
    }
    
    @Test func useParameters() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpClient { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            try #require(body["parameters"] == .object(["foo": .string("bar")]))
            await didConnect.complete()
            return AsyncThrowingChannel()
        })
        
        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            params: ["foo": .string("bar")]
        ))
        await didConnect.await()
        try await db.disconnect()
    }
    
    @Test func useAppMetadata() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpClient { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            try #require(body["app_metadata"] == .object(["app_version": .string("1.0.0")]))
            await didConnect.complete()
            return AsyncThrowingChannel()
        })
        
        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            appMetadata: ["app_version": "1.0.0"]
        ))
        await didConnect.await()
        try await db.disconnect()
    }
    
    @Test func cannotUpdateSchemaWhileConnected() async throws {
        let db = openDatabase(MockHttpClient { request in AsyncThrowingChannel() })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        
        await #expect(throws: PowerSyncError.self) {
            try await db.updateSchema(schema: Schema())
        }

        try await db.close()
    }
    
    @Test func partialSync() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let checksums = Array((0...3).map { prio in BucketChecksum(bucket: "bucket\(prio)", priority: .init(prio), checksum: 10 + prio) })
        var operationId = 1
        
        func pushData(priority: Int32) async throws {
            let id = operationId
            operationId += 1
            
            try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "bucket\(priority)", data: [
                OplogEntry(
                    checksum: priority + 10,
                    op_id: String(id),
                    object_id: String(id),
                    object_type: "users",
                    op: .put,
                    data: String(data: StreamingSyncClient.jsonEncoder.encode([
                        "name": "user \(priority)"
                    ]), encoding: .utf8)!
                )
            ])))
        }
        
        let db = openDatabase(MockHttpClient { request in channel })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }
        
        try await expectUserCount(db, 0)
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "4", buckets: checksums)))
        // Emit a partial sync complete for each priority but the last
        for priorityNo in Int32(0)..<3 {
            try await pushData(priority: priorityNo)
            let priority = BucketPriority(priorityNo)
            try await channel.pushLine(.checkpointPartiallyComplete(lastOpId: String(operationId), priority: priority))
            
            await waitForStatus(db.currentStatus) { $0.statusForPriority(priority).hasSynced == true }
            try await expectUserCount(db, priorityNo + 1)
        }
        
        // Then complete the sync
        try await pushData(priority: 3)
        try await channel.pushLine(.checkpointComplete(lastOpId: String(operationId)))
        try await db.waitForFirstSync()
        try await expectUserCount(db, 4)
        
        try await db.disconnect()
    }
    
    @Test func setsDownloadingState() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }
        
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [.init(bucket: "bkt", checksum: 0)])))
        await waitForStatus(db.currentStatus) { $0.downloading }
        
        try await channel.pushLine(.checkpointComplete(lastOpId: "1"))
        await waitForStatus(db.currentStatus) { !$0.downloading }
        try await db.disconnect()
    }
    
    @Test func setsConnectingState() async throws {
        let didSeeConnecting = Signal()
        
        let db = openDatabase(MockHttpClient { request in
            await didSeeConnecting.await()
            return AsyncThrowingChannel()
        })
        
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connecting }
        await didSeeConnecting.complete()
        await waitForStatus(db.currentStatus) { $0.connected }
    }
    
    @Test func reconnectsAfterDisconnecting() async throws {
        let db = openDatabase(MockHttpClient { request in AsyncThrowingChannel() })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }

        try await db.disconnect()
        await waitForStatus(db.currentStatus) { !$0.connected && !$0.connecting }
        
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }
    }
    
    @Test func reconnects() async throws {
        let db = openDatabase(MockHttpClient { request in AsyncThrowingChannel() })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }
        
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { !$0.connected }
        await waitForStatus(db.currentStatus) { $0.connected }
    }
    
    // TODO: "handles checkpoints during uploads" test
    
    // TODO: "handles write made while offline" test
    
    @Test func tokenExpired() async throws {
        final class BackendConnector: PowerSyncBackendConnectorProtocol {
            let fetchCredentialsCalls = Atomic(0)
            
            func fetchCredentials() async throws -> PowerSyncCredentials? {
                fetchCredentialsCalls.add(1, ordering: .sequentiallyConsistent)
                return testCredentials
            }

            func uploadData(database: any PowerSyncDatabaseProtocol) async throws {}
        }
        
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel })
        let connector = BackendConnector()
        try await db.connect(connector: connector, options: ConnectOptions(retryDelay: 0))
        
        try await channel.pushLine(.keepAlive(tokenExpiresIn: 4000))
        await waitForStatus(db.currentStatus) { $0.connected }
        try #require(connector.fetchCredentialsCalls.load(ordering: .sequentiallyConsistent) == 1)

        // Should invalidate credentials when token expires
        try await channel.pushLine(.keepAlive(tokenExpiresIn: 0))
        await waitForStatus(db.currentStatus) { !$0.connected }
        await waitForStatus(db.currentStatus) { $0.connected }
        try #require(connector.fetchCredentialsCalls.load(ordering: .sequentiallyConsistent) == 2)
    }
    
    @Test func tokenThrows() async throws {
        actor BackendConnector: PowerSyncBackendConnectorProtocol {
            var isFirstFetchCall = true
            
            func fetchCredentials() async throws -> PowerSyncCredentials? {
                if isFirstFetchCall {
                    isFirstFetchCall = false
                    throw PowerSyncError.operationFailed(message: "error in connector")
                }
                return testCredentials
            }
            
            func uploadData(database: any PowerSyncDatabaseProtocol) async throws {}
        }
        
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel })
        try await db.connect(connector: BackendConnector(), options: ConnectOptions(retryDelay: 0.2))
        await waitForStatus(db.currentStatus) { !$0.connected && $0.downloadError != nil }
        
        // Should retry, and the second fetchCredentials call will work
        await waitForStatus(db.currentStatus) { $0.connected }
    }
    
    @Test func tokenPrefetch() async throws {
        actor BackendConnector: PowerSyncBackendConnectorProtocol {
            let prefetchCalled = Signal()
            let completePrefetch = Signal()
            var fetchCredentialsCount = 0
            
            func fetchCredentials() async throws -> PowerSyncCredentials? {
                fetchCredentialsCount += 1
                if fetchCredentialsCount == 2 {
                    await prefetchCalled.complete()
                    await completePrefetch.await()
                }
                return testCredentials
            }

            func uploadData(database: any PowerSyncDatabaseProtocol) async throws {}
        }
        
        let connector = BackendConnector()
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel })
        try await db.connect(connector: connector, options: ConnectOptions())
        
        try await channel.pushLine(.keepAlive(tokenExpiresIn: 4000))
        await waitForStatus(db.currentStatus) { $0.connected }
        try #require(await connector.fetchCredentialsCount == 1)

        try await channel.pushLine(.keepAlive(tokenExpiresIn: 10))
        await connector.prefetchCalled.await()
        // Should still be connected before prefetch completes
        try #require(db.currentStatus.connected == true)

        // After the prefetch completes, we should reconnect.
        await connector.completePrefetch.complete()
        await waitForStatus(db.currentStatus) { !$0.connected }
        await waitForStatus(db.currentStatus) { $0.connected }
        try #require(await connector.fetchCredentialsCount == 2)
    }

    @Test func rawTablesWithImplicitStatements() async throws {
        struct List: Equatable {
            let id: String
            let name: String
        }
        
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel }, schema: Schema(RawTable(name: "lists", schema: RawTableSchema())))
        
        try await db.execute("CREATE TABLE lists (id TEXT NOT NULL PRIMARY KEY, name TEXT)")
        var query = try db.watch("SELECT * FROM lists") { cursor in
            List(id: try cursor.getString(index: 0), name: try cursor.getString(index: 1))
        }.makeAsyncIterator()
        try #require(try await query.next() == [])
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: [
            OplogEntry(
                checksum: 0,
                op_id: "1",
                object_id: "my_list",
                object_type: "lists",
                op: .put,
                data: #"{"name": "custom list"}"#
            )
        ])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "1"))
        try #require(try await query.next() == [List(id: "my_list", name: "custom list")])
        
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "2", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: [
            OplogEntry(
                checksum: 0,
                op_id: "2",
                object_id: "my_list",
                object_type: "lists",
                op: .remove,
            )
        ])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "2"))
        try #require(try await query.next() == [])
    }
    
    @Test func rawTablesWithExplicitStatements() async throws {
        struct List: Equatable {
            let id: String
            let name: String
            let rest: String
        }
        
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel }, schema: Schema(RawTable(
            name: "lists",
            put: PendingStatement(sql: "INSERT OR REPLACE INTO lists (id, name, _rest) VALUES (?, ?, ?)", parameters: [
                .id,
                .column("name"),
                .rest
            ]),
            delete: PendingStatement(sql: "DELETE FROM lists WHERE id = ?", parameters: [
                .id
            ]),
        )))
        
        try await db.execute("CREATE TABLE lists (id TEXT NOT NULL PRIMARY KEY, name TEXT, _rest TEXT)")
        var query = try db.watch("SELECT * FROM lists") { cursor in
            List(id: try cursor.getString(index: 0), name: try cursor.getString(index: 1), rest: try cursor.getString(index: 2))
        }.makeAsyncIterator()
        try #require(try await query.next() == [])
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: [
            OplogEntry(
                checksum: 0,
                op_id: "1",
                object_id: "my_list",
                object_type: "lists",
                op: .put,
                data: #"{"name": "custom list", "additional_column": "foo"}"#
            )
        ])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "1"))
        try #require(try await query.next() == [List(id: "my_list", name: "custom list", rest: #"{"additional_column":"foo"}"#)])
        
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "2", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: [
            OplogEntry(
                checksum: 0,
                op_id: "2",
                object_id: "my_list",
                object_type: "lists",
                op: .remove,
            )
        ])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "2"))
        try #require(try await query.next() == [])
    }
    
    @Test func endsIterationOnHttpClose() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }

        channel.finish()
        await waitForStatus(db.currentStatus) { !$0.connected }
    }

    @Test func syncProgress() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }
        var status = db.currentStatus.asFlow().makeAsyncIterator()
        
        // Send checkpoint with 10 ops, progress should be 0/10
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "10", buckets: [BucketChecksum(bucket: "a", checksum: 0, count: 10)])))
        try (try #require(await status.next())).expectProgress(total: (0, 10))

        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: (0..<10).map { i in
            .init(checksum: 0, op_id: String(i+1), object_id: String(i), object_type: "a", op: .put, data: "{}")
        })))
        try (try #require(await status.next())).expectProgress(total: (10, 10))
        
        // Emit new data, progress should be 0/2 instead of 2/2
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "12", buckets: [
            BucketChecksum(bucket: "a", checksum: 0, count: 12),
        ])))
        try (try #require(await status.next())).expectProgress(total: (10, 12))
        
        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: (10..<12).map { i in
            .init(checksum: 0, op_id: String(i+1), object_id: String(i), object_type: "a", op: .put, data: "{}")
        })))
        try (try #require(await status.next())).expectProgress(total: (12, 12))
    }
}

let defaultSchema = Schema(tables: [
    Table(
        name: "users",
        columns: [
            .text("name"),
        ]
    ),
])

private func openDatabase(_ client: MockHttpClient, schema: Schema = defaultSchema) -> PowerSyncDatabaseProtocol {
    return openKotlinDBDefault(
        schema: schema,
        dbFilename: ":memory:",
        logger: DatabaseLogger(DefaultLogger()),
        httpClient: client
    )
}

let testCredentials = PowerSyncCredentials(
    endpoint: "https://powersynctest.example.org",
    token: "test-token"
)

private final class TestConnector: PowerSyncBackendConnectorProtocol {
    func fetchCredentials() async throws -> PowerSyncCredentials? {
        return testCredentials
    }

    func uploadData(database _: any PowerSync.PowerSyncDatabaseProtocol) async throws {}
}

private final class Signal: Sendable {
    let completer = AsyncChannel<Void>()
    
    func complete() async {
        await completer.send(())
    }
    
    func await() async {
        await completer.first { true }
    }
}

private final class Box<T: ~Copyable & Sendable>: Sendable {
    let inner: T
    
    init(inner: consuming T) {
        self.inner = inner
    }
}

func expectUserCount(_ db: PowerSyncDatabaseProtocol, _ amount: Int32) async throws {
    let users = try await db.getAll("SELECT name FROM users") { $0.getStringOptional(index: 0) }
    try #require(users.count == amount)
}

func waitForStatus(_ status: SyncStatus, predicate: (borrowing SyncStatusData) -> Bool) async {
    if predicate(status) {
        return
    }
    
    let _ = await status.asFlow().first(where: predicate)
}

private extension SyncStatusData {
    func expectProgress(total: (Int32, Int32)) throws {
        let progress = try #require(self.downloadProgress)
        try #require(self.downloading)
        
        try #require(progress.downloadedOperations == total.0)
        try #require(progress.totalOperations == total.1)
    }
}
