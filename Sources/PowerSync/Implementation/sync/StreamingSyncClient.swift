import AsyncAlgorithms
import Foundation

fileprivate let tag = "StreamingSyncClient"

enum CheckpointMode: Sendable {
    /// Uses the legacy `/write-checkpoint2.json` endpoint to obtain a target operation id.
    case legacy
    /// Uses client-generated checkpoint request IDs sent to `/sync/checkpoint-request`.
    case requests
}


final class StreamingSyncClient: Sendable {
    let db: PowerSyncDatabaseImpl
    let options: ConnectOptions
    let connector: CachingCredentialsConnector
    let httpClient: any HttpClient

    let checkpointMode: CheckpointMode
    
    init(
        db: PowerSyncDatabaseImpl,
        connector: PowerSyncBackendConnectorProtocol,
        httpClient: any HttpClient,
        options: ConnectOptions,
    ) {
        self.db = db
        self.connector = CachingCredentialsConnector(inner: connector)
        self.httpClient = httpClient
        self.options = options

        // TODO, make this configurable, or automatically detect
        self.checkpointMode = .requests
    }
    
    /// Starts a task driving uploads and downloads by repeatedly connecting to the PowerSync service,
    /// managing tokens and CRUD uploads.
    ///
    /// There should at most be one such task per database, but this internal method performs no concurrency
    /// control for that (that's the responsibility of a ``SyncCoordinator``).
    func run() -> Task<Void, any Error> {
        Task(name: "StreamingSyncClient.run") {
            let signals = SyncSignals()
            async let download: () = downloadLoop(signals: signals)
            async let upload: () = uploadLoop(signals: signals)
            
            let _ = try await (download, upload)
        }
    }

    private func uploadLoop(signals: SyncSignals) async throws {
        let updates = db.pool.tableUpdates.filter { updates in updates.contains("ps_crud") }.map { _ in () }
        let allTriggers = MergeItemSequence(inner: AsyncAlgorithms.merge(updates, signals.signalCrudUpload.subscribe())).makeAsyncIterator()
        
        // Use a do-while loop to ensure we start an upload iteration even if we can't connect to the service.
        repeat {
            async let crudThrottleDelay = sleepForSeconds(seconds: self.options.crudThrottle)
            try await uploadAllCrud()
            
            db.logger.debug("crud upload: notify completion", tag: tag)
            signals.notifyCrudUploadComplete()
            try await crudThrottleDelay
        } while try await allTriggers.next() != nil
    }
    
    private func uploadAllCrud() async throws {
        var lastUploadItem: Int64? = nil
        
        while (true) {
            defer {
                db.syncStatus.maybeMutateStatus(shouldUpdate: { $0.uploading }, apply: { $0.uploading = false })
            }
            
            do {
                let nextItem = try await db.getOptional("SELECT id FROM ps_crud ORDER BY id LIMIT 1", mapper: { cursor in try cursor.getInt64(index: 0) })
                if let nextItem {
                    if nextItem == lastUploadItem {
                        db.logger.warning("""
Potentially previously uploaded CRUD entries are still present in the upload queue.
Make sure to handle uploads and complete CRUD transactions or batches by calling and awaiting their [.complete()] method.
The next upload iteration will be delayed.
""", tag: tag)
                        throw PowerSyncError.operationFailed(message: "Delaying due to previously encountered CRUD item.")
                    }

                    lastUploadItem = nextItem
                    db.syncStatus.mutateStatus { $0.uploading = true }
                    try await connector.uploadData(database: db)
                } else {
                    // Uploading is completed
                    try await self.uploadLocalTarget()
                    break
                }
            } catch {
                if error is CancellationError {
                    return
                }
                lastUploadItem = nil
                db.syncStatus.mutateStatus {
                    $0.uploading = false
                    $0.internalUploadError = error
                }

                db.logger.error("Error uploading crud: \(error)", tag: tag)
                do {
                    try await sleepForSeconds(seconds: self.options.retryDelay)
                } catch {
                    // Cancelled, abort
                    return
                }
            }
        }
    }

    /// Updates the local target once all currently queued CRUD items have been uploaded.
    ///
    /// When using checkpoint requests, this stores the generated request ID as the local target.
    /// The sync stream later reports the same ID once the corresponding checkpoint has been
    /// applied locally.
    private func uploadLocalTarget() async throws {
        let current_target = try await db.get(
            sql: "SELECT powersync_probe_local_target_op(NULL)",
            parameters: [],
            mapper: { cursor in cursor.getInt64Optional(index: 0) })

        if current_target != PowerSyncDatabaseImpl.maxOpId {
            // We should only update the target if it is currently at the max value
            // This is set after having completed a CRUD Batch/Transaction
            // This avoid overwriting a custom write checkpoint - which would have been set in the .complete handler
            return
        }
        
        // If there never has been any crud items, we don't need to update the checkpoint
        guard let seqBefore = try await db.getOptional("SELECT seq FROM main.sqlite_sequence WHERE name = 'ps_crud'", mapper: { try $0.getInt64(index: 0) }) else {
            return // Nothing to update
        }
        
        // Fetch the appropriate checkpoint ID from the implemnetation
        let opId = try await getWriteCheckpoint()
        
        // This is inside a write transaction, to prevent conflicts with other writes
        try await db.writeTransaction { tx in
            let anyData = try tx.getOptional(sql: "SELECT 1 FROM ps_crud LIMIT 1", parameters: nil) { cursor in 1 }
            if anyData != nil {
                // Additional write after we've obtained the write checkpoint
                return
            }
            
            let seqAfter = try tx.getOptional(sql: "SELECT seq FROM main.sqlite_sequence WHERE name = 'ps_crud'", parameters: nil, mapper: { try $0.getInt64(index: 0) })
            if seqBefore != seqAfter {
                // New crud data may have been uploaded since we got the checkpoint, abort.
                return
            }
            
            // Update the target op
            try tx.execute(sql: "SELECT powersync_probe_local_target_op(?)", parameters: [opId])
        }
    }

    private func handleCommonResponseErrors(response: HTTPURLResponse) async {
        if response.statusCode == 401 {
            await self.invalidateCredentials()
        }
    }

    /// Creates a checkpoint request with a client-generated request ID.
    ///
    /// The request ID is persisted by the core extension before it is sent to the service, so
    /// later sync status updates can report when the same checkpoint request has been applied.
    public func requestCheckpoint() async throws -> Int64 {
        let clientId = try await db.get("SELECT powersync_client_id()") { try $0.getString(index: 0) }

        // Bump the request_id on the client side
        let request_id = try await db.writeTransaction {ctx in 
            return try ctx.get(sql: "SELECT powersync_next_checkpoint_request_id()", parameters: []) {cursor in try cursor.getInt64(index: 0)}
        }
        // Report it to the PowerSync service
        // Note: It's fine if the service rejects this, we only actually set the target later
        var (_, request) = try await authenticatedRequest { endpoint in
            endpoint.path += "/sync/checkpoint-request"
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try StreamingSyncClient.jsonEncoder.encode(CheckpointRequestPayload(
            client_id: clientId,
            checkpoint_request_id: request_id
        ))
        let (response, _) = try await httpClient.readFully(request: request)
        await self.handleCommonResponseErrors(response: response)
        if response.statusCode != 200 {
            throw PowerSyncError.operationFailed(message: "Error getting write checkpoint: \(response.statusCode)")
        }
        return request_id
    }

    private func getWriteCheckpoint() async throws -> String {
        switch checkpointMode  {
            case .requests:
                // Bump the request_id on the client side
                return String(try await requestCheckpoint())
            case .legacy:
                let clientId = try await db.get("SELECT powersync_client_id()") { try $0.getString(index: 0) }
                let (_, request) = try await authenticatedRequest { endpoint in
                    endpoint.path += "/write-checkpoint2.json"
                    endpoint.queryItems = [.init(name: "client_id", value: clientId)]
                }
                let (response, data) = try await httpClient.readFully(request: request)
                await self.handleCommonResponseErrors(response: response)
                if response.statusCode != 200 {
                    throw PowerSyncError.operationFailed(message: "Error getting write checkpoint: \(response.statusCode)")
                }
                
                let body = try StreamingSyncClient.jsonDecoder.decode(WriteCheckpointResponse.self, from: data)
                return body.data.write_checkpoint
        }
    }

    private func downloadLoop(signals: SyncSignals) async throws {
        var result = SyncIterationResult()
        
        while (!Task.isCancelled) {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    let iteration = ActiveSyncIteration(syncClient: self, signals: signals)
                    var group: ThrowingTaskGroup<Void, any Error>? = group
                    result = try await iteration.run(group: &group)
                }
            } catch {
                result = SyncIterationResult()
                
                db.logger.error("Error in streamingSync: \(error)", tag: tag)
                db.syncStatus.mutateStatus { $0.internalDownloadError = error }
            }
            
            if !result.hideDisconnect {
                do {
                    try await sleepForSeconds(seconds: options.retryDelay)
                } catch {
                    // Cancelled
                    break
                }
            }
        }
    }
    
    fileprivate func invalidateCredentials() async {
        await self.connector.invalidateCachedCredentials()
    }
    
    private func authenticatedRequest(buildUrl: (inout URLComponents) -> ()) async throws -> (URL, URLRequest) {
        guard let credentials = try await connector.fetchCredentials() else {
            throw PowerSyncError.operationFailed(message: "fetchCredentials() returned nil")
        }
        
        guard var base = URLComponents(string: credentials.endpoint) else {
            throw PowerSyncError.operationFailed(message: "Invalid backend connector URL: \(credentials.endpoint)")
        }
        buildUrl(&base)
        guard let url = base.url else {
            throw PowerSyncError.operationFailed(message: "Invalid resolved backend connector URL: \(base)")
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(await userAgent(), forHTTPHeaderField: "User-Agent")
        return (url, request)
    }
    
    fileprivate func fetchSyncLines(request: JsonParam) async throws -> ControlInvocationsFromStream {
        var (url, httpRequest) = try await authenticatedRequest { endpoint in endpoint.path += "/sync/stream" }
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        httpRequest.httpBody = try StreamingSyncClient.jsonEncoder.encode(request)
        
        let response: HTTPURLResponse
        let stream: any SyncLineResponse
        do {
            (response, stream) = try await httpClient.receiveSyncLines(request: httpRequest)
        } catch {
            if let responseError = error as? UnexpectedResponseError {
                await handleCommonResponseErrors(response: responseError.response)
            }

            throw error
        }

        await handleCommonResponseErrors(response: response)
        if response.statusCode != 200 {
            throw PowerSyncError.operationFailed(message: "POST \(url) failed with status code \(response.statusCode)")
        }

        return ControlInvocationsFromStream(sequence: stream)
    }
    
    static let jsonEncoder = JSONEncoder()
    static let jsonDecoder = JSONDecoder()
}

private struct ActiveSyncIteration: Sendable {
    private let syncClient: StreamingSyncClient
    private let localEvents = BroadcastStream<PowerSyncControlArguments>()
    private let signals: SyncSignals

    init(syncClient: StreamingSyncClient, signals: SyncSignals) {
        self.syncClient = syncClient
        self.signals = signals
    }
    
    func run(group: inout ThrowingTaskGroup<Void, any Error>?) async throws -> SyncIterationResult {
        // Notify the core extension for changed Sync Stream subscriptions, as we might have to reconnect.
        async let _ = watchSyncStreams()
        // Notify the core extension for completed crud uploads, as we might want to retry applying a
        // checkpoint in that case.
        async let _ = watchCompletedCrudUploads()

        let initialInstructions = try await powersyncControl(.start(start: StartSyncIteration(
            parameters: syncClient.options.params,
            schema: await syncClient.db.schema.inner,
            includeDefaults: syncClient.options.includeDefaultStreams,
            activeStreams: syncClient.db.group.syncCoordinator.streams.currentStreams,
            appMetadata: syncClient.options.appMetadata,
        )))

        var controlArgs: AsyncMerge2Sequence<ControlInvocationsFromStream, AsyncStream<PowerSyncControlArguments>>?

        for instruction in initialInstructions {
            if case .establishSyncStream(request: let request) = instruction {
                let serviceEvents = try await syncClient.fetchSyncLines(request: request)
                controlArgs = AsyncAlgorithms.merge(serviceEvents, localEvents.subscribe())
            } else {
                try await self.execute(instr: instruction, group: &group)
            }
        }

        guard let controlArgs else {
            // Rust client didn't ask for a connection?? Ok then, end the iteration and retry
            return SyncIterationResult()
        }

        var hadSyncLine = false
        for try await arg in controlArgs {
            let control = try await powersyncControl(arg)
            for instr in control {
                if case let .closeSyncStream(hideDisconnect) = instr {
                    return SyncIterationResult(hideDisconnect: hideDisconnect)
                }

                try await execute(instr: instr, group: &group)
            }

            if !hadSyncLine && arg.isSyncLine() {
                // Trigger a crud upload when receiving the first sync line: We could have
                // pending local writes made while disconnected, so in addition to listening on
                // updates to `ps_crud`, we also need to trigger a CRUD upload in some other cases.
                // We do this on the first sync line because the client is likely to be online in
                // that case.
                hadSyncLine = true
                signals.triggerAsyncCrudUpload()
            }
        }
        
        // We use an immediately-awaited Task.detached here because running the stop command shouldn't
        // get aborted.
        return try await Task.detached {
            let control = try await powersyncControl(.stop)
            for instr in control {
                if case let .closeSyncStream(hideDisconnect) = instr {
                    return SyncIterationResult(hideDisconnect: hideDisconnect)
                }
                
                // Don't pass the task group here, stop instructions shouldn't spawn further async work.
                var group: ThrowingTaskGroup<Void, any Error>? = nil
                try await execute(instr: instr, group: &group)
            }

            return SyncIterationResult()
        }.value
    }

    private func powersyncControl(_ args: PowerSyncControlArguments) async throws -> [Instruction] {
        let rawInstructions = try await syncClient.db.writeTransaction { tx in try args.execute(tx) }
        guard let data = rawInstructions.data(using: .utf8) else {
            throw PowerSyncError.operationFailed(message: "Could not encode raw instructions")
        }
        return try StreamingSyncClient.jsonDecoder.decode([Instruction].self, from: data)
    }

    private func execute(instr: consuming Instruction, group: inout ThrowingTaskGroup<Void, any Error>?) async throws {
        switch (instr) {
        case .logLine(severity: let severity, line: let line):
            let logger = syncClient.db.logger
            switch severity {
            case .debug:
                logger.debug(line, tag: tag)
            case .info:
                logger.info(line, tag: tag)
            case .warning:
                logger.warning(line, tag: tag)
            }
            break;
        case .updateSyncStatus(status: let status):
            syncClient.db.syncStatus.mutateStatus {
                $0.core = status
            }
        case .establishSyncStream(request: _):
            throw PowerSyncError.operationFailed(message: "There can only be one establishSyncStream instruction per sync iteration")
        case .closeSyncStream(hideDisconnect: _):
            throw PowerSyncError.operationFailed(message: "CloseSyncStream must be handled in run() loop")
        case .fetchCredentials(didExpire: let didExpire):
            if didExpire {
                await syncClient.invalidateCredentials()
            } else {
                group?.addTask {
                    do {
                        let _ = try await syncClient.connector.fetchCredentials(allowCached: false)
                        syncClient.db.logger.debug("Stopping because new credentials are available", tag: tag)
                        localEvents.dispatch(event: .didRefreshToken)
                    } catch {
                        syncClient.db.logger.warning("Pre-fetching credentials that are about to expire has failed: \(error)", tag: tag)
                    }
                }
            }
        case .flushFileSystem:
            // Noop on native platforms.
            break;
        case .didCompleteSync:
            syncClient.db.syncStatus.mutateStatus {
                $0.internalDownloadError = nil
            }
        }
    }
    
    private func watchSyncStreams() async throws {
        let changes = syncClient.db.group.syncCoordinator.streams.streamsChanged.subscribe()
        for await change in changes {
            self.localEvents.dispatch(event: .updateSubscriptions(streams: change))
        }
    }
    
    private func watchCompletedCrudUploads() async throws {
        let uploads = signals.signalCrudUploadComplete.subscribe()
        for await _ in uploads {
            self.localEvents.dispatch(event: .completedUpload)
        }
    }
}

/// Wraps an HTTP response by mapping it to control invocations for lines. This also adds an "connection established" / "response ended" prefix and suffix.
fileprivate struct ControlInvocationsFromStream: AsyncSequence, Sendable {
    typealias AsyncIterator = ControlInvocationsFromStreamIterator
    typealias Element = PowerSyncControlArguments

    let sequence: any SyncLineResponse
    
    func makeAsyncIterator() -> ControlInvocationsFromStreamIterator {
        .beforeStart(self.sequence)
    }
}

fileprivate enum ControlInvocationsFromStreamIterator: AsyncIteratorProtocol {
    typealias Element = PowerSyncControlArguments

    case beforeStart(any SyncLineResponse)
    case isReceiving(any SyncLineResponseIterator)
    case eof
    
    mutating func next() async throws -> PowerSyncControlArguments? {
        switch self {
        case .beforeStart(let sequence):
            self = .isReceiving(sequence.makeAsyncIterator())
            return .connectionEstablished
        case .isReceiving(var iterator):
            let next = try await iterator.next()
            switch next {
            case .none:
                self = .eof
                return .responseStreamEnd
            case .some(.text(contents: let contents)):
                self = .isReceiving(iterator)
                return .textLine(line: contents)
            }
        case .eof:
            return nil
        }
    }
}

private struct SyncIterationResult {
    let hideDisconnect: Bool
    
    init(hideDisconnect: Bool = false) {
        self.hideDisconnect = hideDisconnect
    }
}

/// Allows the concurrent upload and download tasks to communicate.
/// 
/// The download task might request a CRUD upload (when we run into a checkpoint that couldn't
/// be applied due to local data), and the upload task needs to signal completions to the download
/// task (so that we can retry applying a checkpoint).
private struct SyncSignals {
    let signalCrudUpload = BroadcastStream<Void>()
    let signalCrudUploadComplete = BroadcastStream<Void>()

    func triggerAsyncCrudUpload() {
        self.signalCrudUpload.dispatch(event: ())
    }
    
    func notifyCrudUploadComplete() {
        self.signalCrudUploadComplete.dispatch(event: ())
    }
}

struct WriteCheckpointData: Codable {
    let write_checkpoint: String
}

struct WriteCheckpointResponse: Codable {
    let data: WriteCheckpointData
}

private struct CheckpointRequestPayload: Encodable {
    let client_id: String
    let checkpoint_request_id: Int64
}
