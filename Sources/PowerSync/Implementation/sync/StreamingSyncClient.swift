import AsyncAlgorithms
import Foundation

fileprivate let tag = "StreamingSyncClient"

final class StreamingSyncClient: Sendable {
    internal static let defaultCheckpointRequestRetryDelay: TimeInterval = 10

    /// The lowest retry delay production builds will honor for checkpoint requests.
    internal static let minimumCheckpointRequestRetryDelay: TimeInterval = 10

    let db: PowerSyncDatabaseImpl
    let options: ConnectOptions
    let connector: CachingCredentialsConnector
    let httpClient: HttpClient

    let checkpointMode: CheckpointMode
    private let checkpointRequestRetryDelay: TimeInterval
    /// Set when the connector posts checkpoint requests to a custom backend itself.
    private let customCheckpointRequestConnector: (any CustomCheckpointRequestConnector)?
    private let signals = SyncSignals()

    init(
        db: PowerSyncDatabaseImpl,
        connector: PowerSyncBackendConnectorProtocol,
        httpClient: HttpClient,
        options: ConnectOptions,
    ) {
        self.db = db
        self.connector = CachingCredentialsConnector(inner: connector)
        self.httpClient = httpClient
        self.options = options
        self.checkpointMode = options.checkpointMode
        #if DEBUG
        let minimumCheckpointRequestRetryDelay = db.minimumCheckpointRequestRetryDelay
        #else
        let minimumCheckpointRequestRetryDelay = Self.minimumCheckpointRequestRetryDelay
        #endif
        self.checkpointRequestRetryDelay = Self.resolveCheckpointRequestRetryDelay(
            for: options.checkpointMode,
            minimumCheckpointRequestRetryDelay: minimumCheckpointRequestRetryDelay
        )
        self.customCheckpointRequestConnector = connector as? any CustomCheckpointRequestConnector
    }

    internal static func resolveCheckpointRequestRetryDelay(
        for checkpointMode: CheckpointMode,
        minimumCheckpointRequestRetryDelay: TimeInterval = StreamingSyncClient.minimumCheckpointRequestRetryDelay
    ) -> TimeInterval {
        let retryDelay: TimeInterval?
        switch checkpointMode {
        case .requests(checkpointRequestRetryDelay: let configuredRetryDelay):
            retryDelay = configuredRetryDelay
        case .legacy:
            retryDelay = nil
        }

        return max(retryDelay ?? defaultCheckpointRequestRetryDelay, minimumCheckpointRequestRetryDelay)
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
            async let checkpointRequestRetry: () = checkpointRequestRetryLoop(signals: signals)

            let _ = try await (download, upload, checkpointRequestRetry)
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
                    try await self.uploadTargetCheckpointRequest()
                    db.syncStatus.maybeMutateStatus(
                        shouldUpdate: { $0.internalUploadError != nil },
                        apply: { $0.internalUploadError = nil }
                    )
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

    /// Updates the apply gate once all currently queued CRUD items have been uploaded.
    ///
    /// When using checkpoint requests, this stores the generated request ID as the target.
    /// The sync stream later reports the same ID once the corresponding checkpoint has been
    /// applied locally.
    private func uploadTargetCheckpointRequest() async throws {
        let currentTarget: Int64? = try await db.writeTransaction { tx in
            try tx.powersyncTargetCheckpointRequestId()
        }

        if currentTarget != PowerSyncDatabaseImpl.maxOpId {
            // We should only update the target if it is currently at the max value.
            // This is set after having completed a CRUD Batch/Transaction.
            // This avoids overwriting a custom write checkpoint set in the .complete handler.
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
            
            // Update the target checkpoint request id.
            _ = try tx.powersyncTargetCheckpointRequestId(opId)
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
    /// This does not update the target checkpoint request id: explicit checkpoint requests are wait markers,
    /// not local upload gates.
    func requestCheckpoint() async throws -> any CheckpointRequest {
        guard case .requests = checkpointMode else {
            throw CheckpointRequestError.checkpointRequestsNotEnabled
        }

        // Everything below can fail with a transport, auth or database error. Those are mapped to
        // `CheckpointRequestError` so callers can handle request and wait failures together as
        // `CheckpointError`. Cancellation stays a `CancellationError`.
        do {
            // Allocate the request ID locally before reporting it to the service.
            let effectiveRequestId = try await requestNextCheckpointFromService()
            return CheckpointRequestImpl(requestId: effectiveRequestId, db: db)
        } catch let error as CheckpointRequestError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw CheckpointRequestError.operationFailed(
                message: "Failed to create the checkpoint request.",
                underlyingError: error
            )
        }
    }

    /// Sends or affirms a checkpoint request and returns the effective id accepted remotely.
    ///
    /// When the connector implements ``CustomCheckpointRequestConnector``, the request is posted to
    /// the custom backend instead of the service endpoint, with the same state contract.
    private func requestCheckpointFromService(requestId: Int64) async throws -> Int64 {
        let clientId = try await db.get("SELECT powersync_client_id()") { try $0.getString(index: 0) }

        return try await postCheckpointRequest(CheckpointRequestPayload(
            client_id: clientId,
            checkpoint_request_id: requestId
        ))
    }

    /// Posts a checkpoint request payload prepared by core and returns the state accepted remotely.
    private func postCheckpointRequest(_ payload: CheckpointRequestPayload) async throws -> Int64 {
        if let customCheckpointRequestConnector {
            do {
                return try await customCheckpointRequestConnector.postCheckpointRequest(
                    payload.checkpoint_request_id,
                    clientId: payload.client_id
                )
            } catch let error as CheckpointRequestError {
                throw error
            } catch let error as CancellationError {
                // Cancellation is a control signal, not a connector failure.
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
        request.httpBody = try StreamingSyncClient.jsonEncoder.encode(payload)
        let (response, data) = try await httpClient.readFully(
            request: request,
            logger: options.clientConfiguration?.requestLogger
        )
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
    fileprivate func seedCheckpointRequestState(checkpointRequest: CheckpointRequestPayload) async throws {
        do {
            let seed = try await postCheckpointRequest(checkpointRequest)
            _ = try await db.writeTransaction { tx in
                try tx.powersyncSeedCheckpointRequestId(seed)
            }

            signals.markCheckpointsReady()
        } catch CheckpointRequestError.instanceNotSupported {
            // An unsupported service cannot recover through retries, so fail pending callers.
            // Other errors retry with the sync iteration while callers continue waiting.
            signals.failPendingCheckpointRequests(CheckpointRequestError.instanceNotSupported)
            throw CheckpointRequestError.instanceNotSupported
        }
    }

    /// Returns the checkpoint identifier to store as the target after uploads complete.
    ///
    /// With checkpoint requests this allocates and posts a request ID. The caller stores that
    /// concrete ID only after the service accepts it and the CRUD queue is still empty.
    private func getWriteCheckpoint() async throws -> Int64 {
        switch checkpointMode {
        case .requests:
            return try await requestNextCheckpointFromService()
        case .legacy:
            return try await getLegacyWriteCheckpoint()
        }
    }

    private func requestNextCheckpointFromService() async throws -> Int64 {
        let requestId = try await nextCheckpointRequestId()
        return try await requestCheckpointFromService(requestId: requestId)
    }

    private func nextCheckpointRequestId() async throws -> Int64 {
        try await signals.waitForCheckpointRequestsReady()

        return try await db.writeTransaction { ctx in
            try ctx.powersyncNextCheckpointRequestId()
        }
    }

    private func currentCheckpointRequestId() async throws -> Int64? {
        try await db.writeTransaction { ctx in
            try ctx.powersyncCurrentCheckpointRequestId()
        }
    }

    private func checkpointRequestRetryLoop(signals: SyncSignals) async {
        guard case .requests = checkpointMode else {
            return
        }

        while true {
            do {
                // Make sure the system is seeded and ready
                try await signals.waitForCheckpointRequestsReady(wakeDownloadLoop: false)

                // Get the current checkpoint_request_id
                guard let requestId = try await currentCheckpointRequestId(), requestId > 0 else {
                    // This should not be reached. For completeness sake - wait a bit.
                    try await sleepForSeconds(seconds: checkpointRequestRetryDelay)
                    continue
                }

                // Give the request some time to sync
                try await sleepForSeconds(seconds: checkpointRequestRetryDelay)

                // If a new request was made, we should wait again before retrying
                guard try await currentCheckpointRequestId() == requestId else {
                    continue
                }

                // If the request was applied, we don't need to retry
                guard !db.syncStatus.isCheckpointRequestApplied(requestId) else {
                    continue
                }

                // Make sure we are online and ready before making the request
                try await signals.waitForCheckpointRequestsReady(wakeDownloadLoop: false)

                // It's safe if this request races with a new one. The service will reject it.
                db.logger.debug("Retrying checkpoint request id \(requestId)", tag: tag)
                _ = try await requestCheckpointFromService(requestId: requestId)
            } catch CheckpointRequestError.instanceNotSupported {
                return
            } catch is CancellationError {
                return
            } catch {
                db.logger.warning("Error retrying checkpoint request: \(error)", tag: tag)
                do {
                    // Some failures happen before the loop reaches its scheduled retry sleep,
                    // so back off here too instead of spinning until the next successful readiness check.
                    try await sleepForSeconds(seconds: checkpointRequestRetryDelay)
                } catch {
                    return
                }
            }
        }
    }

    private func getLegacyWriteCheckpoint() async throws -> Int64 {
        let clientId = try await db.get("SELECT powersync_client_id()") { try $0.getString(index: 0) }
        let (_, request) = try await authenticatedRequest { endpoint in
            endpoint.path += "/write-checkpoint2.json"
            endpoint.queryItems = [.init(name: "client_id", value: clientId)]
        }
        let (response, data) = try await httpClient.readFully(request: request, logger: options.clientConfiguration?.requestLogger)
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
        let stream: SyncLineResponse
        do {
            (response, stream) = try await httpClient.receiveSyncLines(request: httpRequest, logger: options.clientConfiguration?.requestLogger)
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
        try jsonDecoder.decode(WriteCheckpointResponse.self, from: data).data.write_checkpoint
    }

    private static func decodeCheckpointRequestId(from data: Data) throws -> Int64 {
        try jsonDecoder.decode(CheckpointRequestResponse.self, from: data).data.checkpoint_request_id
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
        let (currentStreams, streamChanges) = syncClient.db.group.syncCoordinator.streams.observeActiveStreams()
        async let _ = watchSyncStreams(changes: streamChanges)
        // Notify the core extension for completed crud uploads, as we might want to retry applying a
        // checkpoint in that case.
        async let _ = watchCompletedCrudUploads()

        let initialInstructions = try await powersyncControl(.start(start: StartSyncIteration(
            parameters: syncClient.options.params,
            schema: await syncClient.db.schema.inner,
            includeDefaults: syncClient.options.includeDefaultStreams,
            activeStreams: currentStreams,
            appMetadata: syncClient.options.appMetadata,
            checkpointMode: syncClient.checkpointMode,
        )))

        var controlArgs: SyncControlEvents?

        for instruction in initialInstructions {
            if case .establishSyncStream(request: let request, checkpointRequest: let checkpointRequest) = instruction {
                // Start checkpoint request validation while establishing the sync stream, but
                // don't block line processing on it. Operations that allocate checkpoint
                // requests wait for the validation signal themselves.
                // Keeping this as a separate task also lets stream-establishment errors stay primary.
                // We do this on every connect attempt to cater for:
                //   - retries: if the user is offline initially
                //   - rare edge cases where the user_id might have changed between connect invocations 
                let checkpointRequestStateSeed = Task {
                    try await prepareCheckpointRequestState(checkpointRequest)
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
                        serviceEvents,
                        checkpointRequestStateValidationEvents(task: checkpointRequestStateSeed),
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

    private func prepareCheckpointRequestState(_ checkpointRequest: CheckpointRequestPayload?) async throws {
        switch syncClient.checkpointMode {
        case .legacy:
            signals.markCheckpointsReady()
        case .requests:
            guard let checkpointRequest else {
                fatalError("PowerSync core did not provide checkpoint request state while checkpoint request mode is enabled.")
            }
            try await syncClient.seedCheckpointRequestState(checkpointRequest: checkpointRequest)
        }
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
            syncClient.db.syncStatus.mutateStatus { $0.core = status }
        case .establishSyncStream(request: _, checkpointRequest: _):
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
        case .didCompleteSync:
            syncClient.db.syncStatus.mutateStatus {
                $0.internalDownloadError = nil
            }
        case .handleDiagnostics:
            break
        }
    }
    
    private func watchSyncStreams(changes: AsyncStream<[StreamKey]>) async throws {
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
fileprivate typealias SyncControlEvents = AsyncMerge3Sequence<
    ControlInvocationsFromStream,
    CheckpointRequestStateValidationEvents,
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

    let sequence: SyncLineResponse
    
    func makeAsyncIterator() -> ControlInvocationsFromStreamIterator {
        .beforeStart(self.sequence)
    }
}

fileprivate enum ControlInvocationsFromStreamIterator: AsyncIteratorProtocol {
    typealias Element = PowerSyncControlArguments

    case beforeStart(SyncLineResponse)
    case isReceiving(SyncLineResponseIterator)
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
    @StringEncodedInt64 var write_checkpoint: Int64
}

struct CheckpointRequestResponse: Codable {
    let data: CheckpointRequestResponseData
}

struct CheckpointRequestResponseData: Codable {
    @StringEncodedInt64 var checkpoint_request_id: Int64
}

struct CheckpointRequestPayload: Codable {
    let client_id: String
    @StringEncodedInt64 var checkpoint_request_id: Int64
}
