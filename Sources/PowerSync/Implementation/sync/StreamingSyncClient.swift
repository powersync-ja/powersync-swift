import AsyncAlgorithms
import Foundation

fileprivate let tag = "StreamingSyncClient"

final class StreamingSyncClient: Sendable {
    let db: PowerSyncDatabaseImpl
    let options: ConnectOptions
    let connector: CachingCredentialsConnector
    let httpClient: any HttpClient
    
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
        // TODO: Replace with better watch mechanism once we've dropped the Kotlin dependency and can use onChange.
        let watch = try db.watch(sql: "SELECT 1 FROM ps_crud LIMIT 1", parameters: [], mapper: { _ in () })
            .dropFirst() // Skip initial result, we just want to watch changes
            .map { _ in () }
        let allTriggers = AsyncAlgorithms.merge(watch, signals.signalCrudUpload.subscribe())
        
        for try await _ in allTriggers {
            try await uploadAllCrud()
            
            db.logger.debug("crud upload: notify completion", tag: tag)
            signals.notifyCrudUploadComplete()
        }
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
    
    private func uploadLocalTarget() async throws {
        guard let _ = try await db.getOptional(
            sql: "SELECT 1 FROM ps_buckets WHERE name = '$local' AND target_op = ?",
            parameters: [PowerSyncDatabaseImpl.maxOpId],
            mapper: { cursor in () }
        ) else {
            return // Nothing to update
        }
        
        guard let seqBefore = try await db.getOptional("SELECT seq FROM main.sqlite_sequence WHERE name = 'ps_crud'", mapper: { try $0.getInt64(index: 0) }) else {
            return // Nothing to update
        }
        
        let opId = try await getWriteCheckpoint()
        
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
            
            try tx.execute(sql: "UPDATE ps_buckets SET target_op = CAST(? AS INTEGER) WHERE name = '$local'", parameters: [opId])
        }
    }
    
    private func getWriteCheckpoint() async throws -> String {
        let clientId = try await db.get("SELECT powersync_client_id()") { try $0.getString(index: 0) }
        let (_, request) = try await authenticatedRequest { endpoint in
            endpoint.path += "/write-checkpoint2.json"
            endpoint.queryItems = [.init(name: "client_id", value: clientId)]
        }
        let (response, data) = try await httpClient.readFully(request: request)
        
        if response.statusCode == 401 {
            await self.invalidateCredentials()
        }
        if response.statusCode != 200 {
            throw PowerSyncError.operationFailed(message: "Error getting write checkpoint: \(response.statusCode)")
        }
        
        let body = try StreamingSyncClient.jsonDecoder.decode(WriteCheckpointResponse.self, from: data)
        return body.data.write_checkpoint
    }

    private func downloadLoop(signals: SyncSignals) async throws {
        var result = SyncIterationResult()
        
        while (!Task.isCancelled) {
            do {
                // This async let ensures each iteration is a task scoped to this block. This allows us to spawn
                // additional tasks in run() that would get cancelled when the main iteration is complete.
                async let iteration = ActiveSyncIteration(syncClient: self, signals: signals).run()
                
                result = try await iteration
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
        
        let (response, stream) = try await httpClient.receiveSyncLines(request: httpRequest)
        if response.statusCode == 401 {
            await invalidateCredentials()
        }
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
    
    func run() async throws -> SyncIterationResult {
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
                try await self.execute(instr: instruction)
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

                try await execute(instr: instr)
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
                
                try await execute(instr: instr)
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

    private func execute(instr: consuming Instruction) async throws {
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
                Task {
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

private func sleepForSeconds(seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
