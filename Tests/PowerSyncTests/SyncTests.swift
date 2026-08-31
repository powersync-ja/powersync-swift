import AsyncAlgorithms
import Foundation
@testable import PowerSync
import Testing

class InMemorySyncIntegrationTests {
    @Test func decodesCoreSyncStatusTimestampsAsMicroseconds() throws {
        let data = """
        {
          "connected": true,
          "connecting": false,
          "priority_status": [
            {
              "priority": 2147483647,
              "last_synced_at": 1740823200000000,
              "has_synced": true
            }
          ],
          "downloading": null,
          "streams": [
            {
              "name": "default_stream",
              "parameters": null,
              "progress": {
                "total": 1,
                "downloaded": 1
              },
              "active": true,
              "is_default": true,
              "has_explicit_subscription": false,
              "expires_at": 1740826800000000,
              "last_synced_at": 1740823200000000,
              "priority": 2147483647
            }
          ]
        }
        """.data(using: .utf8)!

        let status = try StreamingSyncClient.jsonDecoder.decode(CoreDownloadSyncStatus.self, from: data)
        let priority = try #require(status.priorityStatus.first)
        let stream = try #require(status.streams.first)

        #expect(priority.lastSyncedAt?.timeIntervalSince1970 == TimeInterval(1_740_823_200))
        #expect(stream.subscription.lastSyncedAt == TimeInterval(1_740_823_200))
        #expect(stream.subscription.expiresAt == TimeInterval(1_740_826_800))
    }

    @Test func decodesInternalLastAppliedCheckpointRequestIdOnSyncStatus() throws {
        let data = """
        {
          "connected": true,
          "connecting": false,
          "priority_status": [],
          "downloading": null,
          "streams": [],
          "internal_last_applied_checkpoint_request_id": "7"
        }
        """.data(using: .utf8)!

        let status = try StreamingSyncClient.jsonDecoder.decode(CoreDownloadSyncStatus.self, from: data)
        #expect(status.internalLastAppliedCheckpointRequestId == 7)

        let instructionData = """
        [
          {
            "UpdateSyncStatus": {
              "status": {
                "connected": true,
                "connecting": false,
                "priority_status": [],
                "downloading": null,
                "streams": [],
                "internal_last_applied_checkpoint_request_id": "7"
              }
            }
          }
        ]
        """.data(using: .utf8)!

        let instructions = try StreamingSyncClient.jsonDecoder.decode([Instruction].self, from: instructionData)
        guard case .updateSyncStatus(status: let decodedStatus) = try #require(instructions.first) else {
            Issue.record("Expected UpdateSyncStatus with an internal last applied checkpoint request id")
            return
        }
        #expect(decodedStatus.internalLastAppliedCheckpointRequestId == 7)
    }

    @Test func syncStatusTracksInternalLastAppliedCheckpointRequestId() throws {
        let syncStatus = SwiftSyncStatus()
        let data = """
        {
          "connected": true,
          "connecting": false,
          "priority_status": [],
          "downloading": null,
          "streams": [],
          "internal_last_applied_checkpoint_request_id": "7"
        }
        """.data(using: .utf8)!
        let status = try StreamingSyncClient.jsonDecoder.decode(CoreDownloadSyncStatus.self, from: data)

        #expect(!syncStatus.isCheckpointRequestApplied(7))

        syncStatus.mutateStatus { $0.core = status }
        #expect(syncStatus.isCheckpointRequestApplied(7))
    }

    @Test func setsHeaders() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpSession { request in
            try #require(request.value(forHTTPHeaderField: "User-Agent")!.contains("powersync-swift/"))
            try #require(request.value(forHTTPHeaderField: "Authorization") == "Token test-token")
            await didConnect.complete()
            return AsyncThrowingChannel()
        })
        
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await didConnect.await()
        try await db.close()
    }

    @Test func useParameters() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpSession { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            try #require(body["parameters"] == .object(["foo": .string("bar")]))
            await didConnect.complete()
            return AsyncThrowingChannel()
        })

        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            params: ["foo": .string("bar")]
        ))
        await didConnect.await()
        try await db.close()
    }

    @Test func useAppMetadata() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpSession { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            try #require(body["app_metadata"] == .object(["app_version": .string("1.0.0")]))
            await didConnect.complete()
            return AsyncThrowingChannel()
        })

        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            appMetadata: ["app_version": "1.0.0"]
        ))
        await didConnect.await()
        try await db.close()
    }

    @Test func cannotUpdateSchemaWhileConnected() async throws {
        let db = openDatabase(MockHttpSession { request in AsyncThrowingChannel() })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())

        await #expect(throws: PowerSyncError.self) {
            try await db.updateSchema(schema: Schema())
        }

        try await db.close()
    }

    @Test func partialSync() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
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

        let db = openDatabase(MockHttpSession { request in channel })
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

        try await db.close()
    }

    @Test func handlesUnicodeLineSeparatorsInSyncedData() async throws {
        // Regression test for https://github.com/powersync-ja/powersync-swift/issues/167
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }

        let nameWithLineSeparator = "line one\u{2028}line two"
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.syncDataBucket(SyncDataBucket(bucket: "a", data: [
            OplogEntry(
                checksum: 0,
                op_id: "1",
                object_id: "1",
                object_type: "users",
                op: .put,
                data: String(data: StreamingSyncClient.jsonEncoder.encode(["name": nameWithLineSeparator]), encoding: .utf8)!
            )
        ])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "1"))
        try await db.waitForFirstSync()

        try await expectUserCount(db, 1)
        let names = try await db.getAll("SELECT name FROM users") { try $0.getString(index: 0) }
        try #require(names == [nameWithLineSeparator])
    }

    @Test func setsDownloadingState() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }

        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [.init(bucket: "bkt", checksum: 0)])))
        await waitForStatus(db.currentStatus) { $0.downloading }

        try await channel.pushLine(.checkpointComplete(lastOpId: "1"))
        await waitForStatus(db.currentStatus) { !$0.downloading }
        try await db.close()
    }
    
    @Test func setsConnectingState() async throws {
        let didSeeConnecting = Signal()

        let db = openDatabase(MockHttpSession { request in
            await didSeeConnecting.await()
            return AsyncThrowingChannel()
        })

        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connecting }
        await didSeeConnecting.complete()
        await waitForStatus(db.currentStatus) { $0.connected }
        try await db.close()
    }

    @Test func staysConnectedAfterCancellingConnectionTask() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let mockClient = MockHttpSession { request in channel }
        let db = openDatabase(mockClient)
        let task = Task {
            try await db.connect(connector: TestConnector(), options: ConnectOptions())
        }

        await waitForStatus(db.currentStatus) { $0.connected }
        task.cancel()
        let _ = await task.result

        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [BucketChecksum(bucket: "a", checksum: 0)], writeCheckpoint: "1")))
        await waitForStatus(db.currentStatus) { $0.downloading }
        try await db.close()
    }

    @Test func reconnectsAfterDisconnecting() async throws {
        let db = openDatabase(MockHttpSession { request in AsyncThrowingChannel() })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }

        try await db.disconnect()
        await waitForStatus(db.currentStatus) { !$0.connected && !$0.connecting }

        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }
        try await db.close()
    }

    @Test func reconnects() async throws {
        let db = openDatabase(MockHttpSession { request in AsyncThrowingChannel() })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }

        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { !$0.connected }
        await waitForStatus(db.currentStatus) { $0.connected }
        try await db.close()
    }

    @Test func uploadsWritesMadeBeforeConnecting() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in channel },
            checkpointRequestHook: checkpointRequests.handler()
        )

        try await useDatabase(mockClient) { db in
            try await db.execute(sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)", parameters: ["local write"])
            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))

            var query = try db.watch("SELECT name FROM users") { try $0.getString(index: 0) }.makeAsyncIterator()
            try #require(try await query.next() == ["local write"])

            let uploadTarget = try await waitForPersistedUploadTarget(db)
            #expect(checkpointRequests.contains(uploadTarget))
            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "1",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: String(uploadTarget)
            )))
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
    }
    
    @Test @MainActor func recoversFromUploadErrors() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in channel },
            checkpointRequestHook: checkpointRequests.handler()
        )
        var isFirstUpload = true

        try await useDatabaseOnMainActor(mockClient) { db in
            try await db.execute(sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)", parameters: ["local write"])
            try await db.connect(connector: TestConnector { @MainActor db in
                if isFirstUpload {
                    isFirstUpload = false
                    throw PowerSyncError.operationFailed(message: "Deliberate failure in upload for test", underlyingError: nil)
                }
                let tx = try await db.getNextCrudTransaction()
                try await tx?.complete()
            }, options: ConnectOptions(retryDelay: 0.5, checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.uploadError != nil }

            var query = try db.watch("SELECT name FROM users") { try $0.getString(index: 0) }.makeAsyncIterator()
            try #require(try await query.next() == ["local write"])

            let uploadTarget = try await waitForPersistedUploadTarget(db)
            #expect(checkpointRequests.contains(uploadTarget))
            try #require(db.currentStatus.uploadError == nil)
            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "1",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: String(uploadTarget)
            )))
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

            // The error should have been cleared after the successful upload
            await waitForStatus(db.currentStatus) { $0.uploadError == nil && !$0.uploading }
        }
    }
    
    @Test @MainActor func uploadsOfflineWrites() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let allowConnection = Mutex(false)
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in
                if allowConnection.withLock({ $0 }) {
                    return channel
                }
                throw PowerSyncError.operationFailed(message: "Fake IO error for test", underlyingError: nil)
            },
            checkpointRequestHook: checkpointRequests.handler()
        )

        try await useDatabaseOnMainActor(mockClient) { db in
            // Connect but simulate an IO error from an offline device.
            try await db.connect(connector: TestConnector(), options: ConnectOptions(retryDelay: 0.1, checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.downloadError != nil }

            try await db.execute(sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)", parameters: ["local write"])
            var query = try db.watch("SELECT name FROM users") { try $0.getString(index: 0) }.makeAsyncIterator()
            try #require(try await query.next() == ["local write"])

            allowConnection.withLock { $0 = true }
            // The upload target is usually request ID 2 after the connect-time seed. However, if
            // the local write changes the CRUD sequence while that request is in flight, the
            // upload loop discards it and requests a newer ID. Use the target that was actually
            // persisted instead of assuming a particular scheduling order.
            let persistedUploadTarget = try await waitForPersistedUploadTarget(db)
            #expect(checkpointRequests.contains(persistedUploadTarget))
            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "1",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: String(persistedUploadTarget)
            )))
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
    }

    @Test func requestCheckpointWaitsUntilApplied() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        try await useDatabase(MockHttpSession { request in channel }) { db in
            let dbImpl = try #require(db as? PowerSyncDatabaseImpl)

            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }

            let checkpoint = try await db.requestCheckpoint()
            try #require(!checkpoint.hasSynced)

            // The connect-time seed consumes request ID 1, so this request is ID 2.
            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "0",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: "2"
            )))
            try await channel.pushLine(.checkpointComplete(lastOpId: "0"))

            try await checkpoint.waitForSync(timeout: 1)
            try #require(checkpoint.hasSynced)
            try #require(dbImpl.syncStatus.isCheckpointRequestApplied(2))

            try await db.disconnect()
            try #require(!dbImpl.syncStatus.isCheckpointRequestApplied(2))
            try #require(checkpoint.hasSynced)
        }
    }

    @Test func currentCheckpointRequestIdReportsCurrentSequenceWithoutAllocating() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()

        try await useDatabase(MockHttpSession { _ in channel }) { db in
            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }

            // The connect-time seed consumes request ID 1.
            try await waitUntilAsync {
                try await currentCheckpointRequestId(db) == 1
            }
            try #require(try await currentCheckpointRequestId(db) == 1)

            _ = try await db.requestCheckpoint()
            try #require(try await currentCheckpointRequestId(db) == 2)
            try #require(try await currentCheckpointRequestId(db) == 2)
        }
    }

    @Test func retriesCurrentCheckpointRequestUntilApplied() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in channel },
            checkpointRequestHook: checkpointRequests.handler()
        )
        try await useDatabase(mockClient, minimumCheckpointRequestRetryDelay: 0) { db in
            try await db.connect(
                connector: TestConnector(),
                options: ConnectOptions(checkpointMode: .requests(checkpointRequestRetryDelay: 0.1))
            )
            await waitForStatus(db.currentStatus) { $0.connected }

            let checkpoint = try await db.requestCheckpoint()

            // The connect-time seed consumes request ID 1, so this request is ID 2.
            try await waitUntil(attempts: 5) {
                checkpointRequests.count(of: 2) >= 2
            }

            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "0",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: "2"
            )))
            try await channel.pushLine(.checkpointComplete(lastOpId: "0"))

            try await checkpoint.waitForSync(timeout: 1)
            try #require(checkpoint.hasSynced)
        }
    }

    @Test(.disabled("Flaky in CI"))
    func checkpointRequestRetryWaitsAgainAfterNewRequest() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in channel },
            checkpointRequestHook: checkpointRequests.handler()
        )
        let retryDelay: TimeInterval = 2
        // Scheduling jitter means the observed interval can land just under the configured delay.
        let retryDelayTolerance = retryDelay * 0.9

        try await useDatabase(mockClient, minimumCheckpointRequestRetryDelay: 0) { db in
            try await db.connect(
                connector: TestConnector(),
                options: ConnectOptions(checkpointMode: .requests(checkpointRequestRetryDelay: retryDelay))
            )
            await waitForStatus(db.currentStatus) { $0.connected }

            _ = try await db.requestCheckpoint()
            try await sleepForSeconds(seconds: 0.5)
            _ = try await db.requestCheckpoint()

            // The second request advances the current sequence to 3. Its first retry should
            // observe a fresh interval starting from that newer request.
            try await waitUntil(attempts: 500) {
                checkpointRequests.count(of: 3) >= 2
            }
            let request2Time = try #require(checkpointRequests.timestamps(of: 2).first)
            let request3Times = checkpointRequests.timestamps(of: 3)
            #expect(
                request3Times[0] - request2Time < retryDelay,
                "The newer checkpoint request should arrive before the previous retry interval elapses"
            )
            #expect(
                request3Times[1] - request3Times[0] >= retryDelayTolerance,
                "The latest checkpoint request should wait for the retry interval before being retried"
            )
        }
    }

    @Test func disconnectStopsCheckpointRequestRetryLoop() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in channel },
            checkpointRequestHook: checkpointRequests.handler()
        )
        try await useDatabase(mockClient, minimumCheckpointRequestRetryDelay: 0) { db in
            try await db.connect(
                connector: TestConnector(),
                options: ConnectOptions(checkpointMode: .requests(checkpointRequestRetryDelay: 0.05))
            )
            await waitForStatus(db.currentStatus) { $0.connected }

            _ = try await db.requestCheckpoint()
            try await waitUntil(attempts: 500) {
                checkpointRequests.count(of: 2) >= 2
            }

            try await db.disconnect()
            let requestIdsAfterDisconnect = checkpointRequests.ids
            try await sleepForSeconds(seconds: 0.15)
            try #require(checkpointRequests.ids == requestIdsAfterDisconnect)
        }
    }

    @Test func disconnectCancelsDefaultCheckpointRequestRetryDelay() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in channel },
            checkpointRequestHook: checkpointRequests.handler()
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(
                connector: TestConnector(),
                options: ConnectOptions(checkpointMode: .requests())
            )
            await waitForStatus(db.currentStatus) { $0.connected }

            _ = try await db.requestCheckpoint()
            try #require(checkpointRequests.ids == [1, 2])

            try await sleepForSeconds(seconds: 0.05)
            let start = Date()
            try await db.disconnect()
            #expect(Date().timeIntervalSince(start) < ConnectOptions.defaultRetryDelay)
        }
    }

    @Test func requestCheckpointRequiresCheckpointRequestMode() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()

        try await useDatabase(MockHttpSession { request in channel }) { db in
            try await db.connect(connector: TestConnector(), options: ConnectOptions())
            await waitForStatus(db.currentStatus) { $0.connected }

            do {
                _ = try await db.requestCheckpoint()
                Issue.record("Expected requestCheckpoint() to throw when checkpoint requests are not enabled")
            } catch CheckpointRequestError.checkpointRequestsNotEnabled {
            } catch {
                Issue.record("Expected checkpointRequestsNotEnabled, got \(error)")
            }
        }
    }

    @Test func requestCheckpointRequiresActiveOrConnectingSync() async throws {
        try await useDatabase(MockHttpSession { _ in AsyncThrowingChannel<Data, any Error>() }) { db in
            do {
                _ = try await db.requestCheckpoint()
                Issue.record("Expected requestCheckpoint() to throw without an active or connecting sync client")
            } catch CheckpointRequestError.notConnecting {
            } catch {
                Issue.record("Expected notConnecting, got \(error)")
            }
        }
    }

    @Test func waitForSyncFailsWhenDisconnecting() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        try await useDatabase(MockHttpSession { request in channel }) { db in

            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }

            let checkpoint = try await db.requestCheckpoint()
            try #require(!checkpoint.hasSynced)

            let waiter = Task {
                do {
                    try await checkpoint.waitForSync()
                    Issue.record("Expected waitForSync() to throw after disconnect")
                } catch CheckpointWaitError.disconnected {
                } catch {
                    Issue.record("Expected CheckpointWaitError.disconnected, got \(error)")
                }
            }

            try await db.disconnect()
            await waiter.value
        }
    }

    @Test func waitForSyncFailsWhenClosing() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })

        try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
        await waitForStatus(db.currentStatus) { $0.connected }

        let checkpoint = try await db.requestCheckpoint()
        try #require(!checkpoint.hasSynced)

        let waiter = Task {
            do {
                try await checkpoint.waitForSync()
                Issue.record("Expected waitForSync() to throw after close")
            } catch CheckpointWaitError.disconnected {
            } catch {
                Issue.record("Expected CheckpointWaitError.disconnected, got \(error)")
            }
        }

        try await db.close()
        await waiter.value
    }

    @Test func checkpointRequestRemainsUsableAcrossReconnects() async throws {
        let channels = Mutex<[AsyncThrowingChannel<Data, any Error>]>([])
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in
                let channel = AsyncThrowingChannel<Data, any Error>()
                channels.withLock { $0.append(channel) }
                return channel
            },
            checkpointRequestHook: checkpointRequests.handler()
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }

            let checkpoint = try await db.requestCheckpoint()
            // The connect-time seed consumes request ID 1, so the explicit request is ID 2.
            try #require(checkpointRequests.ids == [1, 2])
            try #require(!checkpoint.hasSynced)

            try await db.disconnect()
            try #require(!checkpoint.hasSynced)
            do {
                try await checkpoint.waitForSync()
                Issue.record("Expected waitForSync() to throw while disconnected")
            } catch CheckpointWaitError.disconnected {
            } catch {
                Issue.record("Expected CheckpointWaitError.disconnected, got \(error)")
            }

            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            // The new connection re-affirms the persisted request counter with the service.
            try await waitUntil { checkpointRequests.ids == [1, 2, 2] }
            try await waitUntil { channels.withLock { $0.count } >= 2 }
            await waitForStatus(db.currentStatus) { $0.connected }

            let channel = channels.withLock { $0[1] }
            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "1",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: "2"
            )))
            try await channel.pushLine(.checkpointComplete(lastOpId: "1"))

            // The request created on the first connection is satisfied by the second one.
            try await checkpoint.waitForSync(timeout: 1)
            try #require(checkpoint.hasSynced)

            // Once applied, the checkpoint request stays synced even without a connection.
            try await db.disconnect()
            try #require(checkpoint.hasSynced)
        }
    }

    @Test func waitForSyncRequiresCheckpointRequestModeAfterReconnect() async throws {
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in AsyncThrowingChannel<Data, any Error>() }
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(
                connector: TestConnector(),
                options: ConnectOptions(checkpointMode: .requests())
            )
            await waitForStatus(db.currentStatus) { $0.connected }
            let checkpoint = try await db.requestCheckpoint()

            try await db.disconnect()
            try await db.connect(connector: TestConnector())
            await waitForStatus(db.currentStatus) { $0.connected }

            do {
                try await checkpoint.waitForSync()
                Issue.record("Expected waitForSync() to require checkpoint request mode")
            } catch CheckpointWaitError.checkpointRequestsNotEnabled {
            } catch {
                Issue.record("Expected CheckpointWaitError.checkpointRequestsNotEnabled, got \(error)")
            }
        }
    }

    @Test func waitForSyncReportsCancellation() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()

        try await useDatabase(MockHttpSession { _ in channel }) { db in
            try await db.connect(
                connector: TestConnector(),
                options: ConnectOptions(checkpointMode: .requests())
            )
            await waitForStatus(db.currentStatus) { $0.connected }

            let checkpoint = try await db.requestCheckpoint()
            try #require(!checkpoint.hasSynced)

            // `SyncStatus.asFlow()` is a non-throwing `AsyncStream`, so a cancelled wait ends the
            // iteration silently. Both overloads must still report cancellation as a
            // `CancellationError` rather than as a disconnect.
            let waiter = Task {
                do {
                    try await checkpoint.waitForSync()
                    Issue.record("Expected waitForSync() to throw when cancelled")
                } catch is CancellationError {
                } catch {
                    Issue.record("Expected CancellationError, got \(error)")
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            waiter.cancel()
            await waiter.value

            let timeoutWaiter = Task {
                do {
                    try await checkpoint.waitForSync(timeout: 30)
                    Issue.record("Expected waitForSync(timeout:) to throw when cancelled")
                } catch is CancellationError {
                } catch {
                    Issue.record("Expected CancellationError, got \(error)")
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            timeoutWaiter.cancel()
            await timeoutWaiter.value
        }
    }

    @Test func requestCheckpointReportsTransportFailuresAsCheckpointErrors() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in channel },
            checkpointRequestHook: { request in
                // Let the connect-time seed (request ID 1) succeed so checkpoint requests become
                // ready, then fail the explicit request with a non-checkpoint transport error.
                guard request.requestId > 1 else {
                    return .checkpointRequestId(request.requestId)
                }
                throw URLError(.notConnectedToInternet)
            }
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(
                connector: TestConnector(),
                options: ConnectOptions(checkpointMode: .requests())
            )
            await waitForStatus(db.currentStatus) { $0.connected }

            do {
                _ = try await db.requestCheckpoint()
                Issue.record("Expected requestCheckpoint() to throw when the request cannot be posted")
            } catch let error as any CheckpointError {
                // Callers drive requestCheckpoint() and waitForSync() in one `do` block and catch
                // both as `CheckpointError`, so transport failures must not escape untyped.
                guard case CheckpointRequestError.operationFailed(_, let underlyingError) = error else {
                    Issue.record("Expected CheckpointRequestError.operationFailed, got \(error)")
                    return
                }
                #expect(underlyingError != nil, "The originating error should be preserved")
            } catch {
                Issue.record("Expected a CheckpointError, got \(type(of: error)): \(error)")
            }
        }
    }

    @Test func requestCheckpointFailsWhenDisconnectedBeforeReady() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in channel },
            checkpointRequestHook: checkpointRequests.handler { request in
                // Block the connect-time seed request so checkpoint requests never become ready.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return .checkpointRequestId(request.requestId)
            }
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))

            let request = Task {
                do {
                    _ = try await db.requestCheckpoint()
                    Issue.record("Expected requestCheckpoint() to throw after disconnect")
                } catch CheckpointRequestError.notConnecting {
                } catch {
                    Issue.record("Expected notConnecting, got \(error)")
                }
            }

            // Wait for the blocked seed request to arrive so the client is mid-validation.
            try await waitUntil { checkpointRequests.ids.count >= 1 }
            try await db.disconnect()
            await request.value
        }
    }

    @Test func requestCheckpointThrowsInstanceNotSupportedWhenServiceDoesNotSupportEndpoint() async throws {
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in AsyncThrowingChannel<Data, any Error>() },
            checkpointRequestHook: { _ in .statusCode(404) }
        )
        // The endpoint is missing on this service, so every request fails. A new sync iteration
        // revalidates checkpoint request support, so the failure must be persistent.

        try await useDatabase(mockClient) { db in
            try await db.connect(
                connector: TestConnector(),
                options: ConnectOptions(retryDelay: 60, checkpointMode: .requests())
            )
            await waitForStatus(db.currentStatus) { $0.downloadError != nil }

            let downloadError = try #require(db.currentStatus.downloadError as? CheckpointRequestError)
            guard case .instanceNotSupported = downloadError else {
                Issue.record("Expected instanceNotSupported download error, got \(downloadError)")
                return
            }

            do {
                _ = try await db.requestCheckpoint()
                Issue.record("Expected requestCheckpoint() to throw instanceNotSupported")
            } catch CheckpointRequestError.instanceNotSupported {
            } catch {
                Issue.record("Expected instanceNotSupported, got \(error)")
            }
        }
    }

    @Test func streamErrorIsPreferredWhenCheckpointRequestValidationAlsoFails() async throws {
        let streamErrorMessage = "Fake stream error for test"
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in
                throw PowerSyncError.operationFailed(message: streamErrorMessage)
            },
            checkpointRequestHook: { _ in .statusCode(404) }
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(
                connector: TestConnector(),
                options: ConnectOptions(retryDelay: 60, checkpointMode: .requests())
            )
            await waitForStatus(db.currentStatus) { $0.downloadError != nil }

            let downloadError = try #require(db.currentStatus.downloadError as? PowerSyncError)
            guard case .operationFailed(message: let message, underlyingError: nil) = downloadError,
                  message == streamErrorMessage else {
                Issue.record("Expected stream error, got \(downloadError)")
                return
            }
        }
    }

    @Test func requestCheckpointUsesEffectiveCheckpointId() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointResponses = Mutex<[Int64?]>([nil, 5])
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in channel },
            checkpointRequestHook: checkpointRequests.handler { request in
                let response = checkpointResponses.withLock { responses in
                    responses.isEmpty ? nil : responses.removeFirst()
                }

                return .checkpointRequestId(response ?? request.requestId)
            }
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }

            let checkpoint = try await db.requestCheckpoint()
            try #require(checkpointRequests.ids == [1, 2])
            try #require(try await lastRequestedCheckpointRequestId(db) == 2)

            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "1",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: "5"
            )))
            try await channel.pushLine(.checkpointComplete(lastOpId: "1"))

            try await checkpoint.waitForSync(timeout: 1)
            try #require(checkpoint.hasSynced)
        }
    }

    @Test func requestCheckpointAllowsLowerEffectiveCheckpointId() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in channel },
            checkpointRequestHook: checkpointRequests.handler { _ in .checkpointRequestId(1) }
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }
            _ = try await db.requestCheckpoint()

            let checkpoint = try await db.requestCheckpoint()
            try #require(checkpointRequests.ids == [1, 2, 3])
            try #require(try await lastRequestedCheckpointRequestId(db) == 3)

            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "1",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: "1"
            )))
            try await channel.pushLine(.checkpointComplete(lastOpId: "1"))

            try await checkpoint.waitForSync(timeout: 1)
            try #require(checkpoint.hasSynced)
        }
    }

    @Test func requestCheckpointSkipsDownloadRetryDelay() async throws {
        let firstAttempt = Signal()
        let channel = AsyncThrowingChannel<Data, any Error>()
        let connectionCount = Mutex(0)
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in
                let count = connectionCount.withLock {
                    $0 += 1
                    return $0
                }

                if count == 1 {
                    await firstAttempt.complete()
                    throw PowerSyncError.operationFailed(message: "Fake IO error for test")
                }

                return channel
            },
            checkpointRequestHook: checkpointRequests.handler()
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: TestConnector(), options: ConnectOptions(retryDelay: 60, checkpointMode: .requests()))
            await firstAttempt.await()
            await waitForStatus(db.currentStatus) { $0.downloadError != nil }

            // A checkpoint request only interrupts an active retry delay. Give the download loop
            // an opportunity to enter that delay after publishing the download error.
            try await sleepForSeconds(seconds: 0.05)

            let requestTask = Task {
                try await db.requestCheckpoint()
            }
            defer {
                requestTask.cancel()
            }

            try await waitUntil {
                connectionCount.withLock { $0 } >= 2
            }

            let checkpoint = try await requestTask.value
            // The failed first iteration cancels its seed task, so whether that seed's request
            // reaches the service before cancellation is a scheduling race. The successful
            // iteration always re-affirms ID 1 before the explicit request allocates ID 2.
            try #require(checkpointRequests.ids.suffix(2) == [1, 2])
            try #require(!checkpoint.hasSynced)
        }
    }

    @Test func existingPendingCheckpointRequestDoesNotSkipDownloadRetryDelay() async throws {
        let signals = SyncSignals()

        let firstDelay = Task {
            try await signals.waitForRetryDelayOrPendingCheckpointRequest(seconds: 0.2)
        }
        try await sleepForSeconds(seconds: 0.01)

        let pendingRequest = Task {
            try await signals.waitForCheckpointRequestsReady()
        }
        defer {
            pendingRequest.cancel()
        }

        try await firstDelay.value

        let start = Date()
        try await signals.waitForRetryDelayOrPendingCheckpointRequest(seconds: 0.05)
        #expect(Date().timeIntervalSince(start) >= 0.04)

        signals.failPendingCheckpointRequests(CheckpointRequestError.notConnecting)
        do {
            try await pendingRequest.value
            Issue.record("Expected pending request to fail")
        } catch CheckpointRequestError.notConnecting {
        } catch is CancellationError {
        } catch {
            Issue.record("Expected notConnecting, got \(error)")
        }
    }

    @Test func cancellingCheckpointReadinessWaitDoesNotCancelOtherWaiters() async throws {
        let signals = SyncSignals()
        let cancelledWaiter = Task {
            try await signals.waitForCheckpointRequestsReady(wakeDownloadLoop: false)
        }
        let remainingWaiter = Task {
            try await signals.waitForCheckpointRequestsReady(wakeDownloadLoop: false)
        }

        try await sleepForSeconds(seconds: 0.01)
        cancelledWaiter.cancel()
        do {
            try await cancelledWaiter.value
            Issue.record("Expected the cancelled readiness waiter to throw")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        signals.markCheckpointsReady()
        try await remainingWaiter.value
    }

    @Test func checkpointReadinessWaitPreservesFailureAcrossAffirmationReset() async throws {
        let signals = SyncSignals()
        let waiter = Task {
            try await signals.waitForCheckpointRequestsReady(wakeDownloadLoop: false)
        }

        try await sleepForSeconds(seconds: 0.01)
        signals.failPendingCheckpointRequests(CheckpointRequestError.instanceNotSupported)
        signals.markPendingCheckpointRequestsRequiringAffirmation()
        signals.markCheckpointsReady()

        do {
            try await waiter.value
            Issue.record("Expected the readiness failure that woke the waiter")
        } catch CheckpointRequestError.instanceNotSupported {
        } catch {
            Issue.record("Expected instanceNotSupported, got \(error)")
        }
    }

    @Test func appliedCheckpointRequestUsesLatestSyncStatusValue() throws {
        let syncStatus = SwiftSyncStatus()

        func status(appliedRequestId: Int64) throws -> CoreDownloadSyncStatus {
            let data = """
            {
              "connected": true,
              "connecting": false,
              "priority_status": [],
              "downloading": null,
              "streams": [],
              "internal_last_applied_checkpoint_request_id": "\(appliedRequestId)"
            }
            """.data(using: .utf8)!

            return try StreamingSyncClient.jsonDecoder.decode(CoreDownloadSyncStatus.self, from: data)
        }

        let status10 = try status(appliedRequestId: 10)
        syncStatus.mutateStatus { $0.core = status10 }
        #expect(syncStatus.isCheckpointRequestApplied(10))

        let status7 = try status(appliedRequestId: 7)
        syncStatus.mutateStatus { $0.core = status7 }
        #expect(syncStatus.isCheckpointRequestApplied(7))
        #expect(!syncStatus.isCheckpointRequestApplied(10))
    }

    @Test func usesSeededCheckpointRequestCounterOnConnect() async throws {
        let didConnect = Signal()
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in
                await didConnect.complete()
                return channel
            },
            checkpointRequestHook: checkpointRequests.handler { _ in .checkpointRequestId(7) }
        )

        try await useDatabase(mockClient) { db in
            try await setTargetCheckpointRequestId(db, 7)
            try await setLastRequestedCheckpointRequestId(db, 4)

            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await didConnect.await()
            try await waitUntilAsync {
                try await lastRequestedCheckpointRequestId(db) == 7
            }

            try #require(checkpointRequests.ids == [7])
            try #require(try await lastRequestedCheckpointRequestId(db) == 7)
            try #require(try await targetCheckpointRequestId(db) == 7)
            try #require(try await nextCheckpointRequestId(db) == 8)
        }
    }

    @Test func seedsEmptyCheckpointRequestCounterOnConnect() async throws {
        let didConnect = Signal()
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in
                await didConnect.complete()
                return channel
            },
            checkpointRequestHook: checkpointRequests.handler()
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await didConnect.await()
            // The connect-time seed affirms and consumes request ID 1, so the first real request
            // will allocate ID 2.
            try await waitUntilAsync {
                try await lastRequestedCheckpointRequestId(db) == 1
            }

            try #require(checkpointRequests.ids == [1])
            try #require(try await lastRequestedCheckpointRequestId(db) == 1)
            try #require(try await nextCheckpointRequestId(db) == 2)
        }
    }

    @Test func checkpointRequestConnectorHandlesCheckpointRequests() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in channel },
            checkpointRequestHook: checkpointRequests.handler()
        )
        let connector = TestCheckpointRequestConnector()

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: connector, options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }

            let checkpoint = try await db.requestCheckpoint()
            // The connect-time seed (ID 1) and the explicit request (ID 2) both go to the connector.
            try #require(connector.postedCheckpointRequests == [1, 2])
            let clientId = try await db.get("SELECT powersync_client_id()") { try $0.getString(index: 0) }
            try #require(connector.postedCheckpointClientIds == [clientId, clientId])
            // The service endpoint is never used with a custom checkpoint request connector.
            try #require(checkpointRequests.ids.isEmpty)

            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "0",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: "2"
            )))
            try await channel.pushLine(.checkpointComplete(lastOpId: "0"))

            try await checkpoint.waitForSync(timeout: 1)
            try #require(checkpoint.hasSynced)
        }
    }

    @Test func checkpointRequestConnectorPropagatesCheckpointRequestErrors() async throws {
        final actor BackendConnector: CustomCheckpointRequestConnector {
            var checkpointRequests = 0

            func fetchCredentials() async throws -> PowerSyncCredentials? {
                testCredentials
            }

            func uploadData(database: any PowerSyncDatabaseProtocol) async throws {}

            func postCheckpointRequest(_ checkpointRequestId: Int64, clientId: String) async throws -> Int64 {
                checkpointRequests += 1
                if checkpointRequests == 1 {
                    return checkpointRequestId
                }
                throw CheckpointRequestError.instanceNotSupported
            }
        }

        let channel = AsyncThrowingChannel<Data, any Error>()
        let connector = BackendConnector()

        try await useDatabase(MockHttpSession { _ in channel }) { db in
            try await db.connect(connector: connector, options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }
            try await waitUntilAsync {
                await connector.checkpointRequests == 1
            }

            do {
                _ = try await db.requestCheckpoint()
                Issue.record("Expected custom checkpoint request error to propagate")
            } catch CheckpointRequestError.instanceNotSupported {
            } catch {
                Issue.record("Expected instanceNotSupported, got \(error)")
            }
        }
    }

    @Test func checkpointRequestConnectorWrapsCustomErrors() async throws {
        final actor BackendConnector: CustomCheckpointRequestConnector {
            var checkpointRequests = 0

            func fetchCredentials() async throws -> PowerSyncCredentials? {
                testCredentials
            }

            func uploadData(database: any PowerSyncDatabaseProtocol) async throws {}

            func postCheckpointRequest(_ checkpointRequestId: Int64, clientId: String) async throws -> Int64 {
                checkpointRequests += 1
                if checkpointRequests == 1 {
                    return checkpointRequestId
                }
                throw PowerSyncError.operationFailed(message: "raw connector failure")
            }
        }

        let channel = AsyncThrowingChannel<Data, any Error>()
        let connector = BackendConnector()

        try await useDatabase(MockHttpSession { _ in channel }) { db in
            try await db.connect(connector: connector, options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }
            try await waitUntilAsync {
                await connector.checkpointRequests == 1
            }

            do {
                _ = try await db.requestCheckpoint()
                Issue.record("Expected custom checkpoint request error to be wrapped")
            } catch CheckpointRequestError.operationFailed(let message, let underlyingError) {
                try #require(message == "Custom checkpoint request failed.")
                guard let powerSyncError = underlyingError as? PowerSyncError,
                      case .operationFailed(message: let rawMessage, underlyingError: nil) = powerSyncError,
                      rawMessage == "raw connector failure" else {
                    Issue.record("Expected raw connector error as underlying error, got \(String(describing: underlyingError))")
                    return
                }
            } catch {
                Issue.record("Expected operationFailed, got \(error)")
            }
        }
    }

    @Test func checkpointRequestConnectorReaffirmsRequestOnReconnect() async throws {
        let channels = Mutex<[AsyncThrowingChannel<Data, any Error>]>([])
        let mockClient = MockHttpSession { _ in
            let channel = AsyncThrowingChannel<Data, any Error>()
            channels.withLock { $0.append(channel) }
            return channel
        }
        let connector = TestCheckpointRequestConnector()

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: connector, options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }
            _ = try await db.requestCheckpoint()
            try #require(connector.postedCheckpointRequests == [1, 2])

            try await db.disconnect()
            try await db.connect(connector: connector, options: ConnectOptions(checkpointMode: .requests()))
            // The reconnect seed re-affirms the persisted request with the custom backend.
            try await waitUntil { connector.postedCheckpointRequests == [1, 2, 2] }
        }
    }

    @Test func checkpointRequestConnectorUploadsUseConnectorCheckpoints() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in channel },
            checkpointRequestHook: checkpointRequests.handler()
        )
        let connector = TestCheckpointRequestConnector()

        try await useDatabase(mockClient) { db in
            try await db.execute(sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)", parameters: ["local write"])
            try await db.connect(connector: connector, options: ConnectOptions(checkpointMode: .requests()))

            var query = try db.watch("SELECT name FROM users") { try $0.getString(index: 0) }.makeAsyncIterator()
            try #require(try await query.next() == ["local write"])

            // The upload target is posted to the connector instead of the service.
            let uploadTarget = try await waitForPersistedUploadTarget(db)
            #expect(connector.postedCheckpointRequests.contains(uploadTarget))
            try #require(checkpointRequests.ids.isEmpty)
            try await channel.pushLine(.fullCheckpoint(Checkpoint(
                last_op_id: "1",
                buckets: [BucketChecksum(bucket: "a", checksum: 0)],
                writeCheckpoint: String(uploadTarget)
            )))
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
    }

    @Test func checkpointRequestConnectorSeedsStateFromBackend() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let mockClient = MockHttpSession { request in channel }
        let connector = TestCheckpointRequestConnector()
        // The backend has requests recorded for this client, e.g. from before a local clear.
        connector.stateResponse = 9

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: connector, options: ConnectOptions(checkpointMode: .requests()))
            await waitForStatus(db.currentStatus) { $0.connected }
            try await waitUntilAsync {
                try await lastRequestedCheckpointRequestId(db) == 9
            }

            // The local counter is seeded from the backend state, so new requests don't collide.
            _ = try await db.requestCheckpoint()
            try #require(connector.postedCheckpointRequests == [1, 10])
            try #require(try await lastRequestedCheckpointRequestId(db) == 10)
        }
    }

    @Test func checkpointRequestConnectorWarnsInLegacyMode() async throws {
        let logger = WarningCapturingLogger()

        try await useDatabase(
            MockHttpSession { _ in AsyncThrowingChannel<Data, any Error>() },
            logger: logger
        ) { db in
            try await db.connect(
                connector: TestCheckpointRequestConnector(),
                options: ConnectOptions(checkpointMode: .legacy)
            )

            let warning = try #require(logger.warnings.first { $0.contains("CustomCheckpointRequestConnector") })
            try #require(warning.contains(".requests"))
        }
    }

    @Test func readsSyncLinesBeforeCheckpointRequestStateIsReady() async throws {
        let seedStarted = Signal()
        let finishSeed = Signal()
        let channel = AsyncThrowingChannel<Data, any Error>()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in channel },
            checkpointRequestHook: { request in
                await seedStarted.complete()
                await finishSeed.await()
                return .checkpointRequestId(request.requestId)
            }
        )

        try await useDatabase(mockClient) { db in
            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await seedStarted.await()
            try await waitUntil { db.currentStatus.connected }

            await finishSeed.complete()
            try await waitUntilAsync {
                try await lastRequestedCheckpointRequestId(db) == 1
            }
        }
    }

    @Test func uploadTargetCheckpointRequestUsesSeededCheckpointRequestId() async throws {
        let didUpload = Signal()
        let didConnect = Signal()
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointResponses = Mutex<[Int64]>([9])
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { _ in
                await didConnect.complete()
                return channel
            },
            checkpointRequestHook: checkpointRequests.handler { request in
                let response = checkpointResponses.withLock { responses in
                    responses.isEmpty ? request.requestId : responses.removeFirst()
                }

                return .checkpointRequestId(response)
            }
        )

        try await useDatabase(mockClient) { db in
            try await db.execute(sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)", parameters: ["local write"])
            try await db.connect(connector: TestConnector { db in
                let tx = try await db.getNextCrudTransaction()
                try await tx?.complete()
                await didUpload.complete()
            }, options: ConnectOptions(retryDelay: 0.05, checkpointMode: .requests()))

            await didConnect.await()
            await didUpload.await()
            try await waitUntil { checkpointRequests.ids == [1, 10] }
            try #require(try await lastRequestedCheckpointRequestId(db) == 10)
            try #require(try await targetCheckpointRequestId(db) == 10)
        }
    }

    @Test func seedsConcreteLocalTargetWithoutLastRequestedCheckpointRequestIdOnConnect() async throws {
        let didConnect = Signal()
        let channel = AsyncThrowingChannel<Data, any Error>()
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in
                await didConnect.complete()
                return channel
            },
            checkpointRequestHook: checkpointRequests.handler()
        )

        try await useDatabase(mockClient) { db in
            try await setTargetCheckpointRequestId(db, 4)
            try await clearLastRequestedCheckpointRequestId(db)

            try await db.connect(connector: TestConnector(), options: ConnectOptions(checkpointMode: .requests()))
            await didConnect.await()
            try await waitUntilAsync {
                try await lastRequestedCheckpointRequestId(db) == 4
            }

            try #require(checkpointRequests.ids == [4])
            try #require(try await lastRequestedCheckpointRequestId(db) == 4)
            try #require(try await targetCheckpointRequestId(db) == 4)
            try #require(try await nextCheckpointRequestId(db) == 5)
        }
    }

    @Test func reseedsCheckpointRequestCounterOnReconnect() async throws {
        let firstConnect = Signal()
        let secondConnect = Signal()
        let firstChannel = AsyncThrowingChannel<Data, any Error>()
        let secondChannel = AsyncThrowingChannel<Data, any Error>()
        let connectionCount = Mutex(0)
        let checkpointResponses = Mutex<[Int64]>([4, 9])
        let checkpointRequests = CheckpointRequestRecorder()
        let mockClient = MockHttpSession(
            handleSyncLines: { request in
                let count = connectionCount.withLock {
                    $0 += 1
                    return $0
                }

                if count == 1 {
                    await firstConnect.complete()
                    return firstChannel
                } else {
                    await secondConnect.complete()
                    return secondChannel
                }
            },
            checkpointRequestHook: checkpointRequests.handler { request in
                let response = checkpointResponses.withLock { responses in
                    responses.isEmpty ? request.requestId : responses.removeFirst()
                }

                return .checkpointRequestId(response)
            }
        )

        try await useDatabase(mockClient) { db in
            try await setTargetCheckpointRequestId(db, 4)

            try await db.connect(connector: TestConnector(), options: ConnectOptions(retryDelay: 0.05, checkpointMode: .requests()))
            await firstConnect.await()
            try await waitUntilAsync {
                try await lastRequestedCheckpointRequestId(db) == 4
            }
            try #require(checkpointRequests.ids == [4])

            try await setTargetCheckpointRequestId(db, 9)
            firstChannel.finish()
            await secondConnect.await()
            try await waitUntilAsync {
                try await lastRequestedCheckpointRequestId(db) == 9
            }
            let requestIds = checkpointRequests.ids
            let firstSeedIndex = try #require(requestIds.firstIndex(of: 4))
            let secondSeedIndex = try #require(requestIds.firstIndex(of: 9))
            try #require(firstSeedIndex < secondSeedIndex)
        }
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

        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
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
        try await db.close()
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
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in
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
        try await db.close()
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

        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
        try await db.connect(connector: BackendConnector(), options: ConnectOptions(retryDelay: 0.2))
        await waitForStatus(db.currentStatus) { !$0.connected && $0.downloadError != nil }

        // Should retry, and the second fetchCredentials call will work
        await waitForStatus(db.currentStatus) { $0.connected }
        try await db.close()
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
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
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
        try await db.close()
    }

    @Test func rawTablesWithImplicitStatements() async throws {
        struct List: Equatable {
            let id: String
            let name: String
        }

        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel }, schema: Schema(RawTable(name: "lists", schema: RawTableSchema())))

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
        try await db.close()
    }

    @Test func rawTablesWithExplicitStatements() async throws {
        struct List: Equatable {
            let id: String
            let name: String
            let rest: String
        }

        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel }, schema: Schema(RawTable(
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
        try await db.close()
    }

    @Test func endsIterationOnHttpClose() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await waitForStatus(db.currentStatus) { $0.connected }

        channel.finish()
        await waitForStatus(db.currentStatus) { !$0.connected }
        try await db.close()
    }

    @Test func reportsErrorWhenStreamEndsMidLine() async throws {
        // Regression test: if the response stream closes while a line is still being received (no
        // trailing \n was seen), this indicates a truncated response and should be reported as an
        // error rather than being silently treated as a complete line.
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
        try await db.connect(connector: TestConnector(), options: ConnectOptions(retryDelay: 0))
        await waitForStatus(db.currentStatus) { $0.connected }

        // Send a chunk that doesn't end in a newline, then close the connection, simulating a
        // connection drop in the middle of a line.
        await channel.send(Data(#"{"checkpoint":{"last_op_id":"1""#.utf8))
        channel.finish()

        await waitForStatus(db.currentStatus) { !$0.connected && $0.downloadError != nil }
        let error = try #require(db.currentStatus.downloadError);
        let _ = try #require(error as? UnexpectedEndOfStreamError)
    }

    @Test func syncProgress() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
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
        try await db.close()
    }

    @Test func requestLogger() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
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
        try await db.close()
    }

    @Test func requestLoggerRespectsInfoLevel() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
        let lines: Mutex<[String]> = Mutex([])

        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            clientConfiguration: SyncClientConfiguration(requestLogger: SyncRequestLoggerConfiguration(requestLevel: .info, logHandler: { line in
                lines.withLock { $0.append(line) }
            }))
        ))
        await waitForStatus(db.currentStatus) { $0.connected }
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "0", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "0"))
        try await db.waitForFirstSync()

        let logEntries = lines.withLock { $0 }
        try #require(logEntries.contains("Starting request to POST https://powersynctest.example.org/sync/stream"))
        try #require(logEntries.contains("sending request"))
        try #require(logEntries.contains { $0.hasPrefix("Got response code") })
        // Headers and body should not be logged at the .info level.
        try #require(!logEntries.contains { $0.hasPrefix("with header") })
        try #require(!logEntries.contains { $0.hasPrefix("with body") })
        try #require(!logEntries.contains { $0.hasPrefix("Response line") })
    }

    @Test func requestLoggerRespectsHeadersLevel() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
        let lines: Mutex<[String]> = Mutex([])

        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            clientConfiguration: SyncClientConfiguration(requestLogger: SyncRequestLoggerConfiguration(requestLevel: .headers, logHandler: { line in
                lines.withLock { $0.append(line) }
            }))
        ))
        await waitForStatus(db.currentStatus) { $0.connected }
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "0", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "0"))
        try await db.waitForFirstSync()

        let logEntries = lines.withLock { $0 }
        try #require(logEntries.contains("Starting request to POST https://powersynctest.example.org/sync/stream"))
        try #require(logEntries.contains { $0.contains("with header Authorization: Token test-token") })
        // Body should not be logged at the .headers level.
        try #require(!logEntries.contains { $0.hasPrefix("with body") })
        try #require(!logEntries.contains { $0.hasPrefix("Response line") })
    }

    @Test func requestLoggerRespectsBodyLevel() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
        let lines: Mutex<[String]> = Mutex([])

        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            clientConfiguration: SyncClientConfiguration(requestLogger: SyncRequestLoggerConfiguration(requestLevel: .body, logHandler: { line in
                lines.withLock { $0.append(line) }
            }))
        ))
        await waitForStatus(db.currentStatus) { $0.connected }
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "0", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "0"))
        try await db.waitForFirstSync()

        let logEntries = lines.withLock { $0 }
        try #require(logEntries.contains("Starting request to POST https://powersynctest.example.org/sync/stream"))
        try #require(logEntries.contains { $0.hasPrefix("with body:") })
        try #require(logEntries.contains(#"Response line: {"checkpoint_complete":{"last_op_id":"0"}}"#))
        // Headers should not be logged at the .body level.
        try #require(!logEntries.contains { $0.hasPrefix("with header") })
    }

    @Test func requestLoggerRespectsNoneLevel() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
        let lines: Mutex<[String]> = Mutex([])

        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            clientConfiguration: SyncClientConfiguration(requestLogger: SyncRequestLoggerConfiguration(requestLevel: .none, logHandler: { line in
                lines.withLock { $0.append(line) }
            }))
        ))
        await waitForStatus(db.currentStatus) { $0.connected }
        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "0", buckets: [BucketChecksum(bucket: "a", checksum: 0)])))
        try await channel.pushLine(.checkpointComplete(lastOpId: "0"))
        try await db.waitForFirstSync()

        try #require(lines.withLock { $0 }.isEmpty)
    }

    @Test func requestLoggerLogsWriteCheckpointRequests() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let mockClient = MockHttpSession { request in channel }
        let db = openDatabase(mockClient)
        mockClient.writeCheckpoint = 1
        let lines: Mutex<[String]> = Mutex([])

        try await db.execute(sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)", parameters: ["local write"])
        try await db.connect(connector: TestConnector(), options: ConnectOptions(
            clientConfiguration: SyncClientConfiguration(requestLogger: SyncRequestLoggerConfiguration(requestLevel: .all, logHandler: { line in
                lines.withLock { $0.append(line) }
            }))
        ))

        var query = try db.watch("SELECT name FROM users") { try $0.getString(index: 0) }.makeAsyncIterator()
        try #require(try await query.next() == ["local write"])

        try await channel.pushLine(.fullCheckpoint(Checkpoint(last_op_id: "1", buckets: [BucketChecksum(bucket: "a", checksum: 0)], writeCheckpoint: "1")))
        try await channel.pushLine(.checkpointComplete(lastOpId: "1"))
        try await db.waitForFirstSync()

        let logEntries = lines.withLock { $0 }
        try #require(logEntries.contains { $0.contains("Starting request to GET") && $0.contains("/write-checkpoint2.json") })
        try #require(logEntries.contains { $0.hasPrefix("  Response: ") && $0.contains("write_checkpoint") })
    }

    @Test func canDisableDefaultStreams() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpSession { request in
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
        try await db.close()
    }

    @Test func subscribesWithStreams() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in
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
        try await db.close()
    }

    @Test func canSubscribeToStreamsWithObjectAndArrays() async throws {
        // Regression test for https://github.com/powersync-ja/powersync-kotlin/issues/349, which also affected the Swift SDK.
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in
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
        try await db.close()
    }

    @Test func reportsDefaultStreams() async throws {
        let channel = AsyncThrowingChannel<Data, any Error>()
        let db = openDatabase(MockHttpSession { request in channel })
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
        try await db.close()
    }
    
    @Test func changesSubscriptionsDynamically() async throws {
        let lastRequest = AsyncMutex<JsonParam?>(nil)
        let db = openDatabase(MockHttpSession { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            await lastRequest.withMutex { $0 = body }
            return AsyncThrowingChannel<Data, any Error>()
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
        try await db.close()
    }

    @Test func subscriptionsUpdateWhileOffline() async throws {
        let db = openDatabase(MockHttpSession {
            request in throw PowerSyncError.operationFailed(message: "Unexpected connection", underlyingError: nil)
        })
        // Make sure the database is initialized
        try await db.readLock { _ in }
        var statusUpdates = db.currentStatus.asFlow().makeAsyncIterator()
        let _ = try #require(await statusUpdates.next()) // Initial snapshot

        // Subscribing while offline should add the stream to subscriptions reported in the status.
        let subscription = try await db.syncStream(name: "a", params: nil).subscribe()
        await waitForStatus(db.currentStatus) { status in
            status.forStream(stream: subscription) != nil
        }
        let _ = try #require(db.currentStatus.forStream(stream: subscription))
        try await db.close()
    }

    @Test func unsubscribingMultipleTimesHasNoEffect() async throws {
        let db = openDatabase(MockHttpSession { request in
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
            
            return AsyncThrowingChannel<Data, any Error>()
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
        try await db.close()
    }

    @Test func unsubscribeAll() async throws {
        let didConnect = Signal()
        let db = openDatabase(MockHttpSession { request in
            let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
            if case let .object(streams) = body["streams"] {
                // While we did request a stream, we called unsubscribeAll() before connecting. So it should not
                // be part of the request.
                try #require(streams["subscriptions"] == .array([]))
            } else {
                Issue.record("Should have streams key in body")
            }
            
            await didConnect.complete()
            return AsyncThrowingChannel<Data, any Error>()
        })
        
        let a = try await db.syncStream(name: "a", params: nil).subscribe()
        try await db.syncStream(name: "a", params: nil).unsubscribeAll()
        try await db.connect(connector: TestConnector(), options: ConnectOptions())
        await didConnect.await()
        let _ = consume a
        try await db.close()
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

private func openDatabase(
    _ session: MockHttpSession,
    schema: Schema = defaultSchema,
    logger: any LoggerProtocol = DefaultLogger()
) -> PowerSyncDatabaseImpl {
    return PowerSyncDatabaseImpl(
        identifier: ":memory:",
        activeInstanceStore: DatabaseGroupCollection(),
        logger: logger,
        pool: AsyncConnectionPool(location: .inMemory, logger: DefaultLogger()),
        customHttpClient: session.client,
        schema: schema,
    )
}

private func useDatabase<T>(
    _ client: MockHttpSession,
    schema: Schema = defaultSchema,
    logger: any LoggerProtocol = DefaultLogger(),
    minimumCheckpointRequestRetryDelay: TimeInterval? = nil,
    _ operation: (any PowerSyncDatabaseProtocol) async throws -> T
) async throws -> T {
    let db = openDatabase(client, schema: schema, logger: logger)
    if let minimumCheckpointRequestRetryDelay {
        db.minimumCheckpointRequestRetryDelay = minimumCheckpointRequestRetryDelay
    }
    do {
        let result = try await operation(db)
        try await closeDatabaseAfterUse(db)
        return result
    } catch {
        try? await closeDatabaseAfterUse(db)
        throw error
    }
}

@MainActor
private func useDatabaseOnMainActor<T>(
    _ client: MockHttpSession,
    schema: Schema = defaultSchema,
    logger: any LoggerProtocol = DefaultLogger(),
    _ operation: (any PowerSyncDatabaseProtocol) async throws -> T
) async throws -> T {
    let db = openDatabase(client, schema: schema, logger: logger)
    do {
        let result = try await operation(db)
        try await closeDatabaseAfterUse(db)
        return result
    } catch {
        try? await closeDatabaseAfterUse(db)
        throw error
    }
}

private func closeDatabaseAfterUse(_ db: any PowerSyncDatabaseProtocol) async throws {
    do {
        try await db.disconnect()
    } catch {
        try? await db.close()
        throw error
    }
    try await db.close()
}

private final class CheckpointRequestRecorder: @unchecked Sendable {
    private struct RecordedRequest: Sendable {
        let id: Int64
        let timestamp: TimeInterval
    }

    private let requests = Mutex<[RecordedRequest]>([])

    var ids: [Int64] {
        requests.withLock { $0.map(\.id) }
    }

    func contains(_ requestId: Int64) -> Bool {
        requests.withLock { $0.contains { $0.id == requestId } }
    }

    func count(of requestId: Int64) -> Int {
        requests.withLock { $0.count { $0.id == requestId } }
    }

    func timestamps(of requestId: Int64) -> [TimeInterval] {
        requests.withLock { requests in
            requests.compactMap { $0.id == requestId ? $0.timestamp : nil }
        }
    }

    func handler(
        response: @Sendable @escaping (MockCheckpointRequest) async throws -> MockCheckpointRequestResponse = { request in
            .checkpointRequestId(request.requestId)
        }
    ) -> @Sendable (MockCheckpointRequest) async throws -> MockCheckpointRequestResponse {
        { request in
            self.requests.withLock {
                $0.append(RecordedRequest(
                    id: request.requestId,
                    timestamp: ProcessInfo.processInfo.systemUptime
                ))
            }
            return try await response(request)
        }
    }
}

private func setTargetCheckpointRequestId(_ db: any PowerSyncDatabaseProtocol, _ requestId: Int64) async throws {
    try await db.execute(
        sql: "INSERT OR REPLACE INTO ps_kv(key, value) VALUES('target_checkpoint_request_id', ?)",
        parameters: [requestId]
    )
}

private func targetCheckpointRequestId(_ db: any PowerSyncDatabaseProtocol) async throws -> Int64? {
    try await db.getOptional(
        sql: "SELECT CAST(value AS INTEGER) FROM ps_kv WHERE key = 'target_checkpoint_request_id'",
        parameters: []
    ) { cursor in
        try cursor.getInt64(index: 0)
    }
}

private func waitForPersistedUploadTarget(_ db: any PowerSyncDatabaseProtocol) async throws -> Int64 {
    let targets = try db.watch(
        sql: """
            SELECT CAST(value AS INTEGER)
            FROM ps_kv
            WHERE key = 'target_checkpoint_request_id'
            """,
        parameters: []
    ) { cursor in
        try cursor.getInt64(index: 0)
    }

    for try await targets in targets {
        if let target = targets.first, target != PowerSyncDatabaseImpl.maxOpId {
            return target
        }
    }

    return try #require(
        nil,
        "Expected the target checkpoint request watch to produce a concrete upload target"
    )
}

private func lastRequestedCheckpointRequestId(_ db: any PowerSyncDatabaseProtocol) async throws -> Int64? {
    try await db.getOptional(
        sql: "SELECT CAST(value AS INTEGER) FROM ps_kv WHERE key = 'last_requested_checkpoint_request_id'",
        parameters: []
    ) { cursor in
        try cursor.getInt64(index: 0)
    }
}

private func setLastRequestedCheckpointRequestId(_ db: any PowerSyncDatabaseProtocol, _ requestId: Int64) async throws {
    try await db.execute(
        sql: "INSERT OR REPLACE INTO ps_kv(key, value) VALUES('last_requested_checkpoint_request_id', ?)",
        parameters: [requestId]
    )
}

private func clearLastRequestedCheckpointRequestId(_ db: any PowerSyncDatabaseProtocol) async throws {
    try await db.execute(
        sql: "DELETE FROM ps_kv WHERE key = 'last_requested_checkpoint_request_id'",
        parameters: []
    )
}

private func nextCheckpointRequestId(_ db: any PowerSyncDatabaseProtocol) async throws -> Int64 {
    try await db.writeTransaction { tx in
        try tx.powersyncNextCheckpointRequestId()
    }
}

private func currentCheckpointRequestId(_ db: any PowerSyncDatabaseProtocol) async throws -> Int64? {
    try await db.writeTransaction { tx in
        try tx.powersyncCurrentCheckpointRequestId()
    }
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

/// A connector that handles checkpoint requests itself instead of the service endpoint.
private final class TestCheckpointRequestConnector: CustomCheckpointRequestConnector {
    private let _postedCheckpointRequests = Mutex<[Int64]>([])
    private let _postedCheckpointClientIds = Mutex<[String]>([])
    private let _stateResponse = Mutex<Int64?>(nil)
    private let uploadDataCallback: @Sendable (_ database: any PowerSyncDatabaseProtocol) async throws -> ()

    init(
        uploadDataCallback: @Sendable @escaping (_: any PowerSyncDatabaseProtocol) async throws -> Void = { db in
            let tx = try await db.getNextCrudTransaction()
            try await tx?.complete()
    }) {
        self.uploadDataCallback = uploadDataCallback
    }

    var postedCheckpointRequests: [Int64] {
        _postedCheckpointRequests.withLock { $0 }
    }

    var postedCheckpointClientIds: [String] {
        _postedCheckpointClientIds.withLock { $0 }
    }

    /// A one-shot state response for the next post, simulating a backend whose recorded
    /// request state is newer than the posted ID.
    var stateResponse: Int64? {
        get { _stateResponse.withLock { $0 } }
        set { _stateResponse.withLock { $0 = newValue } }
    }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        return testCredentials
    }

    func uploadData(database: any PowerSync.PowerSyncDatabaseProtocol) async throws {
        try await self.uploadDataCallback(database)
    }

    func postCheckpointRequest(_ checkpointRequestId: Int64, clientId: String) async throws -> Int64 {
        _postedCheckpointRequests.withLock { $0.append(checkpointRequestId) }
        _postedCheckpointClientIds.withLock { $0.append(clientId) }
        let stateResponse = _stateResponse.withLock { state -> Int64? in
            let value = state
            state = nil
            return value
        }
        return stateResponse ?? checkpointRequestId
    }
}

/// A logger recording warning messages so tests can assert on them.
private final class WarningCapturingLogger: LoggerProtocol {
    private let _warnings = Mutex<[String]>([])

    var warnings: [String] {
        _warnings.withLock { $0 }
    }

    func debug(_ message: String, tag: String?) {}
    func info(_ message: String, tag: String?) {}
    func error(_ message: String, tag: String?) {}
    func fault(_ message: String, tag: String?) {}

    func warning(_ message: String, tag: String?) {
        _warnings.withLock { $0.append(message) }
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

func waitUntil(attempts: Int = 100, _ predicate: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<attempts {
        if predicate() {
            return
        }

        try await sleepForSeconds(seconds: 0.05)
    }

    try #require(predicate())
}

func waitUntilAsync(_ predicate: @escaping () async throws -> Bool) async throws {
    for _ in 0..<100 {
        if try await predicate() {
            return
        }

        try await sleepForSeconds(seconds: 0.05)
    }

    try #require(try await predicate())
}

private extension SyncStatusData {
    func expectProgress(total: (Int32, Int32)) throws {
        let progress = try #require(self.downloadProgress)
        try #require(self.downloading)

        try #require(progress.downloadedOperations == total.0)
        try #require(progress.totalOperations == total.1)
    }
}
