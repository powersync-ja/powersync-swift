import AsyncAlgorithms
import Foundation

fileprivate let tag = "StreamingSyncClient"

final class StreamingSyncClient: Sendable {
    let db: PowerSyncDatabaseImpl
    let options: ConnectOptions
    let connector: CachingCredentialsConnector
    let httpClient: any HttpClient

    let checkpointMode: CheckpointMode
    /// Set when the connector posts checkpoint requests to a custom backend itself.
    private let customCheckpointRequestConnector: (any CustomCheckpointRequestConnector)?
    private let signals = SyncSignals()

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
        self.checkpointMode = options.checkpointMode
        self.customCheckpointRequestConnector = connector as? any CustomCheckpointRequestConnector
    }
    
    /// Starts a task driving uploads and downloads by repeatedly connecting to the PowerSync service,
    /// managing tokens and CRUD uploads.
    ///
    /// There should at most be one such task per database, but this internal method performs no concurrency
    /// control for that (that's the responsibility of a ``SyncCoordinator``).
    func run() -> Task<Void, any Error> {
        Task(name: "StreamingSyncClient.run") {
            // Once both loops end, no further sync iteration can resume checkpoint request
            // waiters, so fail any that are still pending instead of leaving them suspended.
            defer { signals.tearDown() }

            async let download: () = downloadLoop(signals: signals)
            async let upload: () = uploadLoop(signals: signals)

            let _ = try await (download, upload)
        }
    }

    private func uploadLoop(signals: SyncSignals) async throws {
        let updates = db.pool.tableUpdates.filter { updates in
            updates.contains("ps_crud") || updates.contains(EXTERNAL_CHANGES_MARKER)
        }.map { _ in () }
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
        let currentTarget: Int64? = try await db.writeTransaction { tx in
            try tx.powersyncLocalTargetOp()
        }

        if currentTarget != PowerSyncDatabaseImpl.maxOpId {
            // We should only update the target if it is currently at the max value
            // This is set after having completed a CRUD Batch/Transaction
            // This avoid overwriting a custom write checkpoint - which would have been set in the .complete handler
            return
        }
        
        // If there never has been any crud items, we don't need to update the checkpoint
        guard let seqBefore = try await db.getOptional("SELECT seq FROM main.sqlite_sequence WHERE name = 'ps_crud'", mapper: { try $0.getInt64(index: 0) }) else {
            return // Nothing to update
        }

        // Allocate or fetch the checkpoint ID that can satisfy this upload's local write gate.
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
            _ = try tx.powersyncLocalTargetOp(opId)
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
    /// later sync-loop events can report when the same checkpoint request has been applied.
    /// This does not update the local target op: explicit checkpoint requests are wait markers,
    /// not local upload gates.
    func requestCheckpoint() async throws -> any CheckpointRequest {
        guard checkpointMode == .requests else {
            throw CheckpointRequestError.checkpointRequestsNotEnabled
        }

        // Allocate the request ID locally before reporting it to the service.
        let requestId = try await nextCheckpointRequestId()
        let effectiveRequestId = try await requestCheckpointFromService(requestId: requestId)
        return CheckpointRequestImpl(requestId: effectiveRequestId, group: db.group)
    }

    func isCheckpointRequestApplied(_ requestId: Int64) -> Bool {
        signals.isCheckpointRequestApplied(requestId)
    }

    /// Waits until core reports a completed sync that applied `requestId` or a newer request.
    ///
    /// Sync status is still observed for errors so callers fail quickly when the active sync loop
    /// reports a download or upload failure, but status no longer drives the success condition.
    func waitForCheckpointRequest(_ requestId: Int64) async throws {
        if isCheckpointRequestApplied(requestId) {
            db.logger.debug("Checkpoint request id \(requestId) already applied", tag: tag)
            return
        }

        db.logger.debug("Waiting for checkpoint request id \(requestId) to be applied", tag: tag)
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer {
                group.cancelAll()
            }

            group.addTask {
                try await self.signals.waitForCheckpointRequestApplied(requestId)
            }

            group.addTask {
                try await self.throwOnSyncError(untilCheckpointRequestApplied: requestId)
            }

            _ = try await group.next()
        }
        db.logger.debug("Finished waiting for checkpoint request id \(requestId)", tag: tag)
    }

    private func throwOnSyncError(untilCheckpointRequestApplied requestId: Int64) async throws {
        for await update in db.currentStatus.asFlow() {
            if isCheckpointRequestApplied(requestId) {
                return
            }

            if let error = update.anyError {
                // `asFlow()` emits the current status first. We intentionally fail fast if the
                // sync client is already in an error state when the caller starts waiting.
                throw CheckpointWaitError.errorDetected(message: String(describing: error))
            }
        }

        try Task.checkCancellation()
        throw CheckpointWaitError.disconnected
    }

    /// Sends or affirms a checkpoint request and returns the effective id accepted remotely.
    ///
    /// When the connector implements ``CustomCheckpointRequestConnector``, the request is posted to
    /// the custom backend instead of the service endpoint, with the same state contract.
    private func requestCheckpointFromService(requestId: Int64) async throws -> Int64 {
        let clientId = try await db.get("SELECT powersync_client_id()") { try $0.getString(index: 0) }

        if let customCheckpointRequestConnector {
            do {
                return try await customCheckpointRequestConnector.postCheckpointRequest(requestId, clientId: clientId)
            } catch let error as CheckpointRequestError {
                throw error
            } catch {
                throw CheckpointRequestError.operationFailed(
                    message: "Custom checkpoint request failed.",
                    underlyingError: error
                )
            }
        }

        var (_, request) = try await authenticatedRequest { endpoint in
            endpoint.path += "/sync/checkpoint-request"
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try StreamingSyncClient.jsonEncoder.encode(CheckpointRequestPayload(
            client_id: clientId,
            checkpoint_request_id: String(requestId)
        ))
        let (response, data) = try await httpClient.readFully(request: request)
        await self.handleCommonResponseErrors(response: response)
        if response.statusCode == 404 {
            throw CheckpointRequestError.instanceNotSupported
        }
        if response.statusCode != 200 {
            throw CheckpointRequestError.operationFailed(message: "Checkpoint request failed with status code: \(response.statusCode)")
        }

        do {
            return try StreamingSyncClient.decodeCheckpointRequestId(from: data)
        } catch {
            throw CheckpointRequestError.operationFailed(
                message: "Invalid checkpoint request response.",
                underlyingError: error
            )
        }
    }

    /// Ensures the core checkpoint request counter has been seeded for the current stream.
    fileprivate func seedCheckpointRequestState(lastCheckpointRequestId: Int64?) async throws {
        guard checkpointMode == .requests else {
            // legacy mode does not require tracking local state
            signals.markCheckpointsReady()
            return
        }

        do {
            // If a concrete target_op is active, checkpoint request ids must start at or above it.
            let concreteLocalTarget = try await db.writeTransaction { tx -> Int64? in
                let localTarget = try tx.powersyncLocalTargetOp()
                guard let localTarget, localTarget > 0, localTarget != PowerSyncDatabaseImpl.maxOpId else {
                    return nil
                }

                return localTarget
            }

            // Start from the largest value known locally. On normal reconnects, this is the core
            // hint. The concrete local target fallback mainly guards legacy-to-request-mode
            // transitions or unusual migrated state where core has a target but no request hint.
            // In most legacy-to-request transitions the service should already have the concrete
            // checkpoint record and return it when we affirm the current request state, so this
            // fallback is likely over-cautious.
            //
            // On a fresh database this affirms request ID 1, which consumes the ID: an affirmed
            // ID must not be reused by a later real request, since a checkpoint created between
            // the affirmation and that request would wrongly satisfy it. Real requests on a
            // fresh database therefore start at 2.
            let startingRequestId = max(lastCheckpointRequestId ?? 0, concreteLocalTarget ?? 0)
            let seed = try await requestCheckpointFromService(requestId: startingRequestId > 0 ? startingRequestId : 1)

            // Seed only when the service returns a different value, such as after disconnectAndClear.
            if lastCheckpointRequestId != seed {
                try await db.writeTransaction { tx in
                    try tx.powersyncSeedCheckpointRequestId(seed)
                }
            }

            signals.markCheckpointsReady()
        } catch CheckpointRequestError.instanceNotSupported {
            signals.failPendingCheckpointRequests(CheckpointRequestError.instanceNotSupported)
            throw CheckpointRequestError.instanceNotSupported
        }
    }

    /// Returns the checkpoint identifier to store as the local target after uploads complete.
    ///
    /// With checkpoint requests this allocates and posts a request ID. The caller stores that
    /// concrete ID only after the service accepts it and the CRUD queue is still empty.
    private func getWriteCheckpoint() async throws -> Int64 {
        switch checkpointMode {
        case .requests:
            return try await requestCheckpointFromService(requestId: try await nextCheckpointRequestId())
        case .legacy:
            return try await getLegacyWriteCheckpoint()
        }
    }

    private func nextCheckpointRequestId() async throws -> Int64 {
        try await signals.waitForCheckpointRequestsReady()

        return try await db.writeTransaction { ctx in
            try ctx.powersyncNextCheckpointRequestId()
        }
    }

    private func getLegacyWriteCheckpoint() async throws -> Int64 {
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

        return try StreamingSyncClient.decodeWriteCheckpointId(from: data)
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
                    try await signals.waitForRetryDelayOrPendingCheckpointRequest(seconds: options.retryDelay)
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

    private static func decodeWriteCheckpointId(from data: Data) throws -> Int64 {
        let checkpoint = try jsonDecoder.decode(WriteCheckpointResponse.self, from: data).data.write_checkpoint
        guard let checkpointId = Int64(checkpoint) else {
            throw PowerSyncError.operationFailed(message: "Invalid write checkpoint returned by service: \(checkpoint)")
        }

        return checkpointId
    }

    private static func decodeCheckpointRequestId(from data: Data) throws -> Int64 {
        let requestId = try jsonDecoder.decode(CheckpointRequestResponse.self, from: data).data.checkpoint_request_id
        guard let checkpointRequestId = Int64(requestId) else {
            throw PowerSyncError.operationFailed(message: "Invalid checkpoint request returned by service: \(requestId)")
        }

        return checkpointRequestId
    }
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
        defer {
            // Checkpoint requests must be reaffirmed against service state after each iteration.
            // This caters for a very rare, but possible, edge case where a BackendConnector might
            // change user sessions between iterations.
            signals.markPendingCheckpointRequestsRequiringAffirmation()
        }

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

        var controlArgs: SyncControlEvents?

        for instruction in initialInstructions {
            if case .establishSyncStream(request: let request, lastCheckpointRequestId: let lastCheckpointRequestId) = instruction {
                // Start checkpoint request validation while establishing the sync stream, but
                // don't block line processing on it. Operations that allocate checkpoint
                // requests wait for the validation signal themselves.
                // Keeping this as a separate task also lets stream-establishment errors stay primary.
                let checkpointRequestStateSeed = Task {
                    try await syncClient.seedCheckpointRequestState(lastCheckpointRequestId: lastCheckpointRequestId)
                }

                do {
                    let serviceEvents = try await syncClient.fetchSyncLines(request: request)
                    // Merge the real stream, the checkpoint-validation sentinel stream and
                    // local events into a single control loop. The validation stream never
                    // yields control arguments: it only finishes when seeding succeeds, or
                    // throws when seeding fails. Since AsyncAlgorithms.merge rethrows failures
                    // from any input sequence, a seed failure still tears down this sync
                    // iteration even while sync-line events are allowed to flow before
                    // checkpoint request state is ready.
                    controlArgs = AsyncAlgorithms.merge(
                        AsyncAlgorithms.merge(
                            serviceEvents,
                            checkpointRequestStateValidationEvents(task: checkpointRequestStateSeed)
                        ),
                        localEvents.subscribe()
                    )
                } catch {
                    let streamError = error
                    checkpointRequestStateSeed.cancel()
                    do {
                        try await checkpointRequestStateSeed.value
                    } catch {
                        // The stream error is the primary failure for this branch: validation
                        // errors are surfaced by the sentinel once the stream has been established.
                    }
                    throw streamError
                }
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
        try await syncClient.db.writeTransaction { tx in
            try tx.powersyncControl(args)
        }
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
        case .establishSyncStream(request: _, lastCheckpointRequestId: _):
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
        case .didCompleteSync(appliedCheckpointRequestId: let appliedCheckpointRequestId):
            if let appliedCheckpointRequestId {
                syncClient.db.logger.debug("Applied checkpoint request id \(appliedCheckpointRequestId)", tag: tag)
                signals.markCheckpointRequestApplied(appliedCheckpointRequestId)
            }
            syncClient.db.syncStatus.mutateStatus {
                $0.internalDownloadError = nil
            }
        case .handleDiagnostics:
            break
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

fileprivate typealias CheckpointRequestStateValidationEvents = AsyncThrowingStream<PowerSyncControlArguments, any Error>
fileprivate typealias SyncControlEvents = AsyncMerge2Sequence<
    AsyncMerge2Sequence<ControlInvocationsFromStream, CheckpointRequestStateValidationEvents>,
    AsyncStream<PowerSyncControlArguments>
>

/// Converts checkpoint request validation into an event stream that only signals completion/error.
///
/// The stream intentionally emits no `PowerSyncControlArguments`. It exists so `AsyncAlgorithms.merge`
/// can monitor the validation task alongside sync-line and local events. If the task throws, the
/// merged control loop throws on iteration and the outer download loop records/retries the error.
fileprivate func checkpointRequestStateValidationEvents(task: Task<Void, any Error>) -> CheckpointRequestStateValidationEvents {
    AsyncThrowingStream<PowerSyncControlArguments, any Error> { continuation in
        let waiter = Task {
            do {
                try await task.value
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { @Sendable _ in
            waiter.cancel()
            task.cancel()
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

struct WriteCheckpointResponse: Codable {
    let data: WriteCheckpointData
}

struct WriteCheckpointData: Codable {
    let write_checkpoint: String
}

struct CheckpointRequestResponse: Codable {
    let data: CheckpointRequestResponseData
}

struct CheckpointRequestResponseData: Codable {
    let checkpoint_request_id: String
}

struct CheckpointRequestPayload: Codable {
    let client_id: String
    let checkpoint_request_id: String
}
