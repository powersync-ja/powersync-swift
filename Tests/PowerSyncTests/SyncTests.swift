import AsyncAlgorithms
import Foundation
@testable import PowerSync
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

    @Test func staysConnectedAfterCancellingConnectionTask() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let mockClient = MockHttpClient { request in channel }
        let db = openDatabase(mockClient)
        let task = Task {
            try await db.connect(connector: TestConnector(), options: ConnectOptions())
        }

        await waitForStatus(db.currentStatus) { $0.connected }
        task.cancel()
        let _ = await task.result

        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [BucketChecksum(bucket: "a", checksum: 0)], writeCheckpoint: "1")))
        await waitForStatus(db.currentStatus) { $0.downloading }
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

    @Test func uploadsWritesMadeBeforeConnecting() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let mockClient = MockHttpClient { request in channel }
        let db = openDatabase(mockClient)
        mockClient.writeCheckpoint = 1

        try await db.execute(sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)", parameters: ["local write"])
        try await db.connect(connector: TestConnector(), options: ConnectOptions())

        var query = try db.watch("SELECT name FROM users") { try $0.getString(index: 0) }.makeAsyncIterator()
        try #require(try await query.next() == ["local write"])

        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [BucketChecksum(bucket: "a", checksum: 0)], writeCheckpoint: "1")))
        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: [OplogEntry(
            checksum: 0,
            op_id: "1",
            object_id: "1",
            object_type: "users",
            op: .put,
            data: #"{"id": "test1", "name": "from server"}"#,
        )])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "1"))
        try #require(try await query.next() == ["from server"])
    }
    
    @Test @MainActor func recoversFromUploadErrors() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let mockClient = MockHttpClient { request in channel }
        let db = openDatabase(mockClient)
        mockClient.writeCheckpoint = 1
        var isFirstUpload = true

        try await db.execute(sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)", parameters: ["local write"])
        try await db.connect(connector: TestConnector { @MainActor db in
            if isFirstUpload {
                isFirstUpload = false
                throw PowerSyncError.operationFailed(message: "Deliberate failure in upload for test", underlyingError: nil)
            }
            let tx = try await db.getNextCrudTransaction()
            try await tx?.complete()
        }, options: ConnectOptions(retryDelay: 0.5))
        await waitForStatus(db.currentStatus) { $0.uploadError != nil }

        var query = try db.watch("SELECT name FROM users") { try $0.getString(index: 0) }.makeAsyncIterator()
        try #require(try await query.next() == ["local write"])

        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [BucketChecksum(bucket: "a", checksum: 0)], writeCheckpoint: "1")))
        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: [OplogEntry(
            checksum: 0,
            op_id: "1",
            object_id: "1",
            object_type: "users",
            op: .put,
            data: #"{"id": "test1", "name": "from server"}"#,
        )])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "1"))
        try #require(try await query.next() == ["from server"])
    }
    
    @Test @MainActor func uploadsOfflineWrites() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        var allowConnection = false
        let mockClient = MockHttpClient { @MainActor request in
            if allowConnection {
                return channel
            }
            throw PowerSyncError.operationFailed(message: "Fake IO error for test", underlyingError: nil)
        }
        let db = openDatabase(mockClient)
        mockClient.writeCheckpoint = 1

        // Connect but simulate an IO error from an offline device.
        try await db.connect(connector: TestConnector(), options: ConnectOptions(retryDelay: 0.1))
        await waitForStatus(db.currentStatus) { $0.downloadError != nil }

        try await db.execute(sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)", parameters: ["local write"])
        var query = try db.watch("SELECT name FROM users") { try $0.getString(index: 0) }.makeAsyncIterator()
        try #require(try await query.next() == ["local write"])
        
        allowConnection = true
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [BucketChecksum(bucket: "a", checksum: 0)], writeCheckpoint: "1")))
        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: [OplogEntry(
            checksum: 0,
            op_id: "1",
            object_id: "1",
            object_type: "users",
            op: .put,
            data: #"{"id": "test1", "name": "from server"}"#,
        )])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "1"))
        try #require(try await query.next() == ["from server"])
    }

    @Test func tokenExpired() async throws {
        final actor BackendConnector: PowerSyncBackendConnectorProtocol {
            var fetchCredentialsCalls = 0

            func fetchCredentials() async throws -> PowerSyncCredentials? {
                fetchCredentialsCalls += 1
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
        try #require(await connector.fetchCredentialsCalls == 1)

        // Should invalidate credentials when token expires
        try await channel.pushLine(.keepAlive(tokenExpiresIn: 0))
        await waitForStatus(db.currentStatus) { !$0.connected }
        await waitForStatus(db.currentStatus) { $0.connected }
        try #require(await connector.fetchCredentialsCalls == 2)
    }

    @Test func handlesThrowing401Response() async throws {
        final actor BackendConnector: PowerSyncBackendConnectorProtocol {
            var fetchCredentialsCalls = 0

            func fetchCredentials() async throws -> PowerSyncCredentials? {
                fetchCredentialsCalls += 1
                return testCredentials
            }

            func uploadData(database: any PowerSyncDatabaseProtocol) async throws {}
        }

        let connector = BackendConnector()
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in
            if await connector.fetchCredentialsCalls == 1 {
                // On a real 401 response, the platform client would throw because the body can't be interpreted as sync lines.
                // This verifies the sync client can recognize that and reset credentials.
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                throw UnexpectedResponseError(response: response, message: "Expected error to retry fetching credentials")
            } else {
                return channel
            }
        })

        try await db.connect(connector: connector, options: ConnectOptions(retryDelay: 0))
        await waitForStatus(db.currentStatus) { $0.connected }
        try #require(await connector.fetchCredentialsCalls == 2)
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
        let _ = await status.next() // Skip initial

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

    @Test func requestLogger() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel })
        let lines: Mutex<[String]> = Mutex([])

        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            clientConfiguration: SyncClientConfiguration(requestLogger: SyncRequestLoggerConfiguration(requestLevel: .all, logHandler: { line in
                lines.withLock { $0.append(line) }
            }))
        ))
        await waitForStatus(db.currentStatus) { $0.connected }
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "0", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "0"))
        try await db.waitForFirstSync()

        let logEntries = lines.withLock { $0 }
        try #require(logEntries.contains("Starting request to POST https://powersynctest.example.org/sync/stream"))
        try #require(logEntries.contains(#"Response line: {"checkpoint_complete":{"last_op_id":"0"}}"#))
    }

    @Test func canDisableDefaultStreams() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpClient { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            if case let .object(options) = body["streams"] {
                try #require(options["include_defaults"] == .bool(false))
            } else {
                Issue.record("Should have streams key in body")
            }

            await didConnect.complete()
            return AsyncThrowingChannel()
        })

        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            includeDefaultStreams: false
        ))
        await didConnect.await()
    }

    @Test func subscribesWithStreams() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            if case let .object(streams) = body["streams"] {
                try #require(streams["include_defaults"] == .bool(true))
                try #require(streams["subscriptions"] == .array([
                    .object([
                        "stream": .string("stream"),
                        "parameters": .object(["foo": .string("a")]),
                        "override_priority": .null
                    ]),
                    .object([
                        "stream": .string("stream"),
                        "parameters": .object(["foo": .string("b")]),
                        "override_priority": .int(1)
                    ])
                ]))
            } else {
                Issue.record("Should have streams key in body")
            }
            
            return channel
        })

        let a = try await db.syncStream(name:"stream", params: ["foo": .string("a")]).subscribe()
        let b = try await db.syncStream(name: "stream", params: ["foo": .string("b")]).subscribe(ttl: nil, priority: .init(1))
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }
        var statusUpdates = db.currentStatus.asFlow().makeAsyncIterator()
        let _ = await statusUpdates.next() // Skip initial

        // Without an initial checkpoint, sync streams should not be marked as active
        try #require(db.currentStatus.forStream(stream: a)?.subscription.hasSynced == false)
        try #require(db.currentStatus.forStream(stream: b)?.subscription.hasSynced == false)

        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [
            BucketChecksum(
                bucket: "a",
                priority: BucketPriority(3),
                checksum: 0,
                subscriptions: [.explicitSubscription(0)]
            ),
            BucketChecksum(
                bucket: "b",
                priority: BucketPriority(1),
                checksum: 0,
                subscriptions: [.explicitSubscription(1)]
            )
        ], streams: [StreamDescription(name: "stream", is_default: false)])))

        // Subscriptions should be active now, but not marked as synced
        do {
            let status = try #require(await statusUpdates.next())
            for subscription in [a, b] {
                let status = try #require(status.forStream(stream: subscription))
                try #require(status.subscription.active)
                try #require(status.subscription.lastSyncedAt == nil)
                try #require(status.subscription.hasExplicitSubscription)
            }
        }

        try await channel.pushLine(.checkpointPartiallyComplete(lastOpId: "0", priority: BucketPriority(1)))
        do {
            let status = try #require(await statusUpdates.next())
            try #require(status.forStream(stream: a)!.subscription.lastSyncedAt == nil)
            try #require(status.forStream(stream: b)!.subscription.lastSyncedAt != nil)
            try await b.waitForFirstSync()
        }

        try await channel.pushLine(.checkpointComplete(lastOpId: "0"))
        try await a.waitForFirstSync()
    }

    @Test func canSubscribeToStreamsWithObjectAndArrays() async throws {
        // Regression test for https://github.com/powersync-ja/powersync-kotlin/issues/349, which also affected the Swift SDK.
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            if case let .object(streams) = body["streams"] {
                try #require(streams["subscriptions"] == .array([
                    .object([
                        "stream": .string("stream"),
                        "parameters": .object([
                            "a": .object([
                                "foo": .string("bar")
                            ]),
                            "b": .array([.string("foo"), .string("bar")])
                        ]),
                        "override_priority": .null
                    ])
                ]))
            } else {
                Issue.record("Should have streams key in body")
            }
            
            return channel
        })

        let params: JsonParam = [
            "a": .object([
                "foo": .string("bar")
            ]),
            "b": .array([.string("foo"), .string("bar")])
        ]
        let stream = try await db.syncStream(name: "stream", params: params).subscribe()
        try await db.connect(connector: TestConnector(), options: ConnectOptions())

        await waitForStatus(db.currentStatus) { $0.connected }
        let streams = try #require(db.currentStatus.syncStreams)
        try #require(streams.count == 1)
        try #require(streams[0].subscription.parameters == params)
        try await stream.unsubscribe()
    }

    @Test func reportsDefaultStreams() async throws {
        let channel = AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        let db = openDatabase(MockHttpClient { request in channel })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())

        await waitForStatus(db.currentStatus) { $0.connected }
        var statusUpdates = db.currentStatus.asFlow().makeAsyncIterator()
        let _ = await statusUpdates.next() // Skip initial
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "0", buckets: [], streams: [StreamDescription(name: "default_stream", is_default: true)])))

        let status = try #require(await statusUpdates.next())
        let stream = try #require(status.syncStreams?.first)
        try #require(stream.subscription.name == "default_stream")
        try #require(stream.subscription.parameters == nil)
        try #require(stream.subscription.isDefault)
        try #require(!stream.subscription.hasExplicitSubscription)
    }
    
    @Test func changesSubscriptionsDynamically() async throws {
        let lastRequest = AsyncMutex<JsonParam?>(nil)
        let db = openDatabase(MockHttpClient { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            await lastRequest.withMutex { $0 = body }
            return AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        })

        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }
        let request = try #require(await lastRequest.inner)
        if case let .object(streams) = request["streams"] {
            try #require(streams["subscriptions"] == .array([]))
        } else {
            Issue.record("Should have streams key in body")
        }

        // Adding a new subscription should reconnect
        let subscription = try await db.syncStream(name: "a", params: nil).subscribe()
        await waitForStatus(db.currentStatus) { !$0.connected }
        await waitForStatus(db.currentStatus) { $0.connected }
        let secondRequest = try #require(await lastRequest.inner)
        if case let .object(streams) = secondRequest["streams"] {
            try #require(streams["subscriptions"] == .array([
                .object([
                    "stream": .string("a"),
                    "parameters": .null,
                    "override_priority": .null,
                ])
            ]))
        } else {
            Issue.record("Should have streams key in body")
        }
        let _ = consume subscription
    }

    @Test func subscriptionsUpdateWhileOffline() async throws {
        let db = openDatabase(PlatformHttpClient.shared)
        var statusUpdates = db.currentStatus.asFlow().makeAsyncIterator()

        // Subscribing while offline should add the stream to subscriptions reported in the status.
        let subscription = try await db.syncStream(name: "a", params: nil).subscribe()
        let status = try #require(await statusUpdates.next())
        let _ = try #require(status.forStream(stream: subscription))
    }

    @Test func unsubscribingMultipleTimesHasNoEffect() async throws {
        let db = openDatabase(MockHttpClient { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            if case let .object(streams) = body["streams"] {
                try #require(streams["subscriptions"] == .array([
                    .object([
                        "stream": .string("a"),
                        "parameters": .null,
                        "override_priority": .null
                    ]),
                ]))
            } else {
                Issue.record("Should have streams key in body")
            }
            
            return AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        })

        let a = try await db.syncStream(name: "a", params: nil).subscribe()
        let aAgain = try await db.syncStream(name: "a", params: nil).subscribe()
        try await a.unsubscribe()
        try await a.unsubscribe()

        // Pretend the streams are expired, they should still be requested because the
        // core extension extends the lifetime of streams currently referenced before connecting
        try await db.execute("UPDATE ps_stream_subscriptions SET expires_at = unixepoch() - 1000")
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }

        let _ = consume aAgain
    }

    @Test func unsubscribeAll() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpClient { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            if case let .object(streams) = body["streams"] {
                // While we did request a stream, we called unsubscribeAll() before connecting. So it should not
                // be part of the request.
                try #require(streams["subscriptions"] == .array([]))
            } else {
                Issue.record("Should have streams key in body")
            }
            
            await didConnect.complete()
            return AsyncThrowingChannel<PowerSync.SyncLine, any Error>()
        })
        
        let a = try await db.syncStream(name: "a", params: nil).subscribe()
        try await db.syncStream(name: "a", params: nil).unsubscribeAll()
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await didConnect.await()
        let _ = consume a
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

private func openDatabase(_ client: any HttpClient, schema: Schema = defaultSchema, logger: any LoggerProtocol = DefaultLogger()) -> PowerSyncDatabaseProtocol {
    return PowerSyncDatabaseImpl(
        identifier: ":memory:",
        activeInstanceStore: DatabaseGroupCollection(),
        logger: logger,
        pool: AsyncConnectionPool(location: .inMemory, logger: DefaultLogger()),
        httpClient: client,
        schema: schema,
    )
}

let testCredentials = PowerSyncCredentials(
    endpoint: "https://powersynctest.example.org",
    token: "test-token"
)

private final class TestConnector: PowerSyncBackendConnectorProtocol {
    private let uploadDataCallback: @Sendable (_ database: any PowerSyncDatabaseProtocol) async throws -> ()

    init(
        uploadDataCallback: @Sendable @escaping (_: any PowerSyncDatabaseProtocol) async throws -> Void = { db in
            let tx = try await db.getNextCrudTransaction()
            try await tx?.complete()
    }) {
        self.uploadDataCallback = uploadDataCallback
    }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        return testCredentials
    }

    func uploadData(database: any PowerSync.PowerSyncDatabaseProtocol) async throws {
        try await self.uploadDataCallback(database)
    }
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

func expectUserCount(_ db: PowerSyncDatabaseProtocol, _ amount: Int32) async throws {
    let users = try await db.getAll("SELECT name FROM users") { $0.getStringOptional(index: 0) }
    try #require(users.count == amount)
}

func waitForStatus(_ status: SyncStatus, predicate: @Sendable (borrowing SyncStatusData) -> Bool) async {
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
