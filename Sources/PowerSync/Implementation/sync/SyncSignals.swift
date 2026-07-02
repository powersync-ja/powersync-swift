import Foundation

/// Shared coordination state for the sync client.
///
/// This bridges upload and download task notifications, tracks when checkpoint requests are safe
/// to allocate after connect-time validation, and resolves explicit checkpoint request waiters when
/// core reports that the requested checkpoint has been applied locally.
final class SyncSignals: Sendable {
    /// Tracks connect-time validation for checkpoint request state.
    ///
    /// Request ID allocation waits on this state so `next_checkpoint_request_id` only runs after
    /// the service has affirmed or seeded the local counter for the active connection.
    private struct CheckpointRequestsState {
        var isReady = false
        /// Terminal readiness failure replayed to checkpoint request callers.
        ///
        /// This is currently set when checkpoint requests are not supported by the service
        /// (for example, a 404 from the seed/affirm route). Other connect-time failures surface
        /// through the normal sync download error path instead.
        var failure: (any Error)?
        /// Waiters blocked before creating new checkpoint request IDs.
        ///
        /// These resume once connect-time checkpoint request state has been seeded or affirmed
        /// against the service.
        var waiters: [AsyncThrowingStream<Void, any Error>.Continuation] = []
    }

    /// A pending waiter for an explicit checkpoint request to be applied locally.
    private struct CheckpointRequestApplicationWaiter {
        let id: Int64
        let requestId: Int64
        let continuation: AsyncThrowingStream<Void, any Error>.Continuation
    }

    /// Tracks the latest applied checkpoint request and waiters for future applied IDs.
    ///
    /// Core emits `CheckpointRequestApplied` when a checkpoint has been applied. We keep the
    /// latest ID here so requests can resolve immediately when they are already satisfied.
    private struct CheckpointRequestApplicationState {
        var latestAppliedRequestId: Int64?
        var nextWaiterId: Int64 = 0
        /// Waiters blocked after a checkpoint request has been created.
        ///
        /// These resume once core emits `CheckpointRequestApplied` with the requested ID or a
        /// newer one.
        var waiters: [CheckpointRequestApplicationWaiter] = []
    }

    let signalCrudUpload = BroadcastStream<Void>()
    let signalCrudUploadComplete = BroadcastStream<Void>()
    private let signalCheckpointRequestWaitingForReady = BroadcastStream<Void>()
    private let shouldSkipRetryDelay = Mutex(false)
    private let checkpointRequests = Mutex(CheckpointRequestsState())
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

    /// Marks checkpoint request allocation as blocked until the next connect-time validation completes.
    func invalidateCheckpointRequests() {
        checkpointRequests.withLock { state in
            state.isReady = false
        }
    }

    /// Marks checkpoint request allocation as safe and resumes callers waiting to create request IDs.
    func markCheckpointRequestsReady() {
        let waiters = checkpointRequests.withLock { state in
            if state.isReady {
                return [] as [AsyncThrowingStream<Void, any Error>.Continuation]
            }

            state.isReady = true
            state.failure = nil
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }

        for waiter in waiters {
            waiter.finish()
        }
    }

    /// Fails checkpoint request readiness and resumes waiting callers by throwing `error`.
    func failCheckpointRequests(_ error: any Error) {
        let waiters = checkpointRequests.withLock { state in
            state.isReady = false
            state.failure = error
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }

        for waiter in waiters {
            waiter.finish(throwing: error)
        }
    }

    /// Waits until checkpoint request IDs can be safely allocated for the active connection.
    ///
    /// Waiting here also asks the download loop to skip its retry delay so connect-time validation
    /// can run promptly after a failed connection attempt.
    func waitForCheckpointRequestsReady() async throws {
        let initialState = checkpointRequests.withLock { state in
            (isReady: state.isReady, failure: state.failure)
        }
        if let failure = initialState.failure {
            throw failure
        }
        if initialState.isReady {
            try Task.checkCancellation()
            return
        }

        shouldSkipRetryDelay.withLock { $0 = true }
        signalCheckpointRequestWaitingForReady.dispatch(event: ())

        let stream = AsyncThrowingStream<Void, any Error> { continuation in
            let immediateResult = checkpointRequests.withLock { state -> Result<Void, any Error>? in
                if let failure = state.failure {
                    return .failure(failure)
                }
                if state.isReady {
                    return .success(())
                }

                state.waiters.append(continuation)
                return nil
            }

            switch immediateResult {
            case .success:
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            case nil:
                break
            }
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
        let waiters = checkpointRequestApplications.withLock { state in
            state.latestAppliedRequestId = max(state.latestAppliedRequestId ?? requestId, requestId)
            guard let latestAppliedRequestId = state.latestAppliedRequestId else {
                return [] as [AsyncThrowingStream<Void, any Error>.Continuation]
            }

            var readyWaiters: [AsyncThrowingStream<Void, any Error>.Continuation] = []
            state.waiters.removeAll { waiter in
                if latestAppliedRequestId >= waiter.requestId {
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

        let stream = AsyncThrowingStream<Void, any Error> { continuation in
            let waiterId = checkpointRequestApplications.withLock { state -> Int64? in
                if let latestAppliedRequestId = state.latestAppliedRequestId, latestAppliedRequestId >= requestId {
                    return nil
                }

                state.nextWaiterId += 1
                let waiterId = state.nextWaiterId
                state.waiters.append(CheckpointRequestApplicationWaiter(
                    id: waiterId,
                    requestId: requestId,
                    continuation: continuation
                ))
                return waiterId
            }

            guard let waiterId else {
                continuation.finish()
                return
            }

            continuation.onTermination = { @Sendable _ in
                self.checkpointRequestApplications.withLock { state in
                    state.waiters.removeAll { $0.id == waiterId }
                }
            }
        }

        for try await _ in stream {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
    }

    /// Waits for the normal retry delay, unless a checkpoint request is waiting for readiness.
    ///
    /// This lets an explicit checkpoint request wake the download loop immediately instead of
    /// waiting for the configured retry delay to elapse.
    func waitForRetryDelayOrCheckpointRequest(seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            return
        }

        if consumeRetryDelaySkip() {
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await sleepForSeconds(seconds: seconds)
            }

            group.addTask {
                let stream = self.signalCheckpointRequestWaitingForReady.subscribe(bufferingPolicy: .bufferingNewest(1))
                if self.consumeRetryDelaySkip() {
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

    private func consumeRetryDelaySkip() -> Bool {
        shouldSkipRetryDelay.withLock { shouldSkip in
            if shouldSkip {
                shouldSkip = false
                return true
            }

            return false
        }
    }
}
