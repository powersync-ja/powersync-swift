import Foundation

/// Shared coordination state for the sync client.
///
/// This bridges upload and download task notifications, tracks when pending checkpoint requests are
/// safe to allocate after connect-time validation, and resolves explicit checkpoint request waiters
/// when core reports that the requested checkpoint has been applied locally.
///
/// There are two distinct checkpoint request waits here:
/// - Pending checkpoint requests wait before ID allocation, until the active connection has seeded
///   or affirmed request state with the service.
/// - Existing checkpoint requests wait after ID allocation, until core reports that the requested
///   checkpoint request ID has been applied locally.
final class SyncSignals: Sendable {
    /// A pending `requestCheckpoint()` caller blocked before creating a checkpoint request ID.
    private struct PendingCheckpointRequestWaiter {
        let id: Int64
        let continuation: AsyncThrowingStream<Void, any Error>.Continuation
    }

    /// Tracks connect-time validation for pending checkpoint request creation.
    ///
    /// Request ID allocation waits on this state so `next_checkpoint_request_id` only runs after
    /// the service has affirmed or seeded the local counter for the active connection.
    private struct PendingCheckpointRequestsState {
        var isReady = false
        /// Terminal readiness failure replayed to pending checkpoint request callers.
        ///
        /// This is set when checkpoint requests are not supported by the service (for example, a
        /// 404 from the seed/affirm route), or when the sync client shuts down. Other connect-time
        /// failures surface through the normal sync download error path instead.
        var failure: (any Error)?
        var nextWaiterId: Int64 = 0
        /// Pending checkpoint requests blocked before creating request IDs.
        ///
        /// These resume once connect-time checkpoint request state has been seeded or affirmed
        /// against the service.
        var waiters: [PendingCheckpointRequestWaiter] = []
    }

    /// A waiter for an existing checkpoint request to be applied locally.
    private struct CheckpointRequestApplicationWaiter {
        let id: Int64
        let requestId: Int64
        let continuation: AsyncThrowingStream<Void, any Error>.Continuation
    }

    /// Tracks the latest applied checkpoint request and waiters for already-created requests.
    ///
    /// Core emits `CheckpointRequestApplied` when a checkpoint has been applied. We keep the
    /// latest ID here so requests can resolve immediately when they are already satisfied.
    private struct CheckpointRequestApplicationState {
        var latestAppliedRequestId: Int64?
        var nextWaiterId: Int64 = 0
        /// Set once the owning sync client shuts down. No further applications can be observed,
        /// so unsatisfied waits fail instead of suspending forever.
        var isTornDown = false
        /// Waiters blocked after a checkpoint request has been created.
        ///
        /// These resume once core emits `CheckpointRequestApplied` with the requested ID or a
        /// newer one.
        var waiters: [CheckpointRequestApplicationWaiter] = []
    }

    let signalCrudUpload = BroadcastStream<Void>()
    let signalCrudUploadComplete = BroadcastStream<Void>()
    private let signalPendingCheckpointRequestWaitingForReady = BroadcastStream<Void>()
    private let pendingCheckpointRequests = Mutex(PendingCheckpointRequestsState())
    private let checkpointRequestApplications = Mutex(CheckpointRequestApplicationState())

    /// Requests that the upload loop starts a CRUD upload attempt soon.
    func triggerAsyncCrudUpload() {
        self.signalCrudUpload.dispatch(event: ())
    }

    /// Notifies the download loop that CRUD upload work completed.
    ///
    /// The core may use this to retry applying a checkpoint that was blocked by local writes.
    func notifyCrudUploadComplete() {
        self.signalCrudUploadComplete.dispatch(event: ())
    }

    /// Marks checkpoint request allocation as blocked until the next connect-time affirmation completes.
    func markPendingCheckpointRequestsRequiringAffirmation() {
        pendingCheckpointRequests.withLock { state in
            state.isReady = false
            // A previous failure (such as an unsupported service) is checked again by the next
            // iteration, so it should not be replayed to new callers in the meantime.
            state.failure = nil
        }
    }

    /// Marks checkpoint processing as safe and resumes pending callers waiting to create request IDs.
    func markCheckpointsReady() {
        let waiters = pendingCheckpointRequests.withLock { state in
            if state.isReady {
                return [] as [PendingCheckpointRequestWaiter]
            }

            state.isReady = true
            state.failure = nil
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }

        for waiter in waiters {
            waiter.continuation.finish()
        }
    }

    /// Fails pending checkpoint requests and resumes callers blocked before ID allocation.
    func failPendingCheckpointRequests(_ error: any Error) {
        let waiters = pendingCheckpointRequests.withLock { state in
            state.isReady = false
            state.failure = error
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }

        for waiter in waiters {
            waiter.continuation.finish(throwing: error)
        }
    }

    /// Permanently fails all pending and future waits after the owning sync client has stopped.
    ///
    /// Without this, a `requestCheckpoint()` or `waitForSync()` caller racing a `disconnect()`
    /// would suspend forever: no further sync iteration exists to resume its waiter.
    func tearDown() {
        failPendingCheckpointRequests(CheckpointRequestError.notConnecting)

        let applicationWaiters = checkpointRequestApplications.withLock { state in
            state.isTornDown = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }

        for waiter in applicationWaiters {
            waiter.continuation.finish(throwing: CheckpointWaitError.disconnected)
        }
    }

    /// Waits until pending checkpoint requests can safely allocate IDs for the active connection.
    ///
    /// Registering a waiter here also wakes the download loop from its retry delay so connect-time
    /// validation can run promptly after a failed connection attempt.
    func waitForCheckpointRequestsReady() async throws {
        let initialState = pendingCheckpointRequests.withLock { state in
            (isReady: state.isReady, failure: state.failure)
        }
        if let failure = initialState.failure {
            throw failure
        }
        if initialState.isReady {
            try Task.checkCancellation()
            return
        }

        enum ImmediateResult {
            case ready
            case failed(any Error)
            case registered(waiterId: Int64)
        }

        var didRegisterWaiter = false
        // This is a one-shot wait; `AsyncThrowingStream` is a convenience because `onTermination`
        // lets us remove the registered waiter when the waiting task is cancelled.
        let stream = AsyncThrowingStream<Void, any Error> { continuation in
            let immediateResult = pendingCheckpointRequests.withLock { state -> ImmediateResult in
                if let failure = state.failure {
                    return .failed(failure)
                }
                if state.isReady {
                    return .ready
                }

                state.nextWaiterId += 1
                let waiterId = state.nextWaiterId
                state.waiters.append(PendingCheckpointRequestWaiter(id: waiterId, continuation: continuation))
                return .registered(waiterId: waiterId)
            }

            switch immediateResult {
            case .ready:
                continuation.finish()
            case .failed(let error):
                continuation.finish(throwing: error)
            case .registered(let waiterId):
                didRegisterWaiter = true
                continuation.onTermination = { @Sendable _ in
                    self.pendingCheckpointRequests.withLock { state in
                        state.waiters.removeAll { $0.id == waiterId }
                    }
                }
            }
        }

        if didRegisterWaiter {
            // Wake the download loop only after the waiter is registered, so
            // `waitForRetryDelayOrPendingCheckpointRequest` observes it when re-checking.
            signalPendingCheckpointRequestWaitingForReady.dispatch(event: ())
        }

        for try await _ in stream {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
    }

    /// Returns whether core has already applied this checkpoint request ID or a newer one.
    func isCheckpointRequestApplied(_ requestId: Int64) -> Bool {
        checkpointRequestApplications.withLock { state in
            guard let latestAppliedRequestId = state.latestAppliedRequestId else {
                return false
            }

            return latestAppliedRequestId >= requestId
        }
    }

    /// Records an applied checkpoint request ID and resumes waiters satisfied by that ID.
    func markCheckpointRequestApplied(_ requestId: Int64) {
        let waiters = checkpointRequestApplications.withLock { state -> [AsyncThrowingStream<Void, any Error>.Continuation] in
            state.latestAppliedRequestId = requestId

            var readyWaiters: [AsyncThrowingStream<Void, any Error>.Continuation] = []
            state.waiters.removeAll { waiter in
                if requestId >= waiter.requestId {
                    readyWaiters.append(waiter.continuation)
                    return true
                }

                return false
            }

            return readyWaiters
        }

        for waiter in waiters {
            waiter.finish()
        }
    }

    /// Waits until core applies this checkpoint request ID or a newer one.
    func waitForCheckpointRequestApplied(_ requestId: Int64) async throws {
        if isCheckpointRequestApplied(requestId) {
            try Task.checkCancellation()
            return
        }

        enum ImmediateResult {
            case applied
            case tornDown
            case registered(waiterId: Int64)
        }

        // This is a one-shot wait; `AsyncThrowingStream` is a convenience because `onTermination`
        // lets us remove the registered waiter when the waiting task is cancelled.
        let stream = AsyncThrowingStream<Void, any Error> { continuation in
            let immediateResult = checkpointRequestApplications.withLock { state -> ImmediateResult in
                if let latestAppliedRequestId = state.latestAppliedRequestId, latestAppliedRequestId >= requestId {
                    return .applied
                }
                if state.isTornDown {
                    return .tornDown
                }

                state.nextWaiterId += 1
                let waiterId = state.nextWaiterId
                state.waiters.append(CheckpointRequestApplicationWaiter(
                    id: waiterId,
                    requestId: requestId,
                    continuation: continuation
                ))
                return .registered(waiterId: waiterId)
            }

            switch immediateResult {
            case .applied:
                continuation.finish()
            case .tornDown:
                continuation.finish(throwing: CheckpointWaitError.disconnected)
            case .registered(let waiterId):
                continuation.onTermination = { @Sendable _ in
                    self.checkpointRequestApplications.withLock { state in
                        state.waiters.removeAll { $0.id == waiterId }
                    }
                }
            }
        }

        for try await _ in stream {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
    }

    /// Waits for the normal retry delay, unless a new checkpoint request starts waiting for readiness.
    ///
    /// This lets an explicit checkpoint request wake the download loop immediately instead of
    /// waiting for the configured retry delay to elapse. Existing pending requests do not skip
    /// the delay: they already had an opportunity to wake the loop when they registered.
    func waitForRetryDelayOrPendingCheckpointRequest(seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            return
        }

        let initialWaiterId = pendingCheckpointRequests.withLock { $0.nextWaiterId }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await sleepForSeconds(seconds: seconds)
            }

            group.addTask {
                let stream = self.signalPendingCheckpointRequestWaitingForReady.subscribe(bufferingPolicy: .bufferingNewest(1))
                // A waiter may have registered between the initial snapshot and this subscription.
                if self.pendingCheckpointRequests.withLock({ $0.nextWaiterId > initialWaiterId }) {
                    return
                }

                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
            }

            let _ = try await group.next()
            group.cancelAll()
            try Task.checkCancellation()
        }
    }
}
