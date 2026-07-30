import Foundation

/// Shared coordination state for the sync client.
///
/// This bridges upload and download task notifications, tracks when pending checkpoint requests are
/// safe to allocate after connect-time validation.
final class SyncSignals: Sendable {
    /// Tracks connect-time validation for pending checkpoint request creation.
    ///
    /// The local checkpoint request counter must be reconciled with the service before a new
    /// request ID can be allocated. Request creation waits on this state until that reconciliation
    /// has completed for the active connection.
    private struct PendingCheckpointRequestsState {
        enum Outcome: Sendable {
            case pending
            case ready
            /// Terminal readiness failure replayed to pending checkpoint request callers.
            ///
            /// This is set when checkpoint requests are not supported by the service (for example,
            /// a 404 from the seed/affirm route), or when the sync client shuts down. Other
            /// connect-time failures surface through the normal sync download error path instead.
            case failed(any Error)
        }

        var outcome = Outcome.pending
        let outcomeChanged = BroadcastStream<Outcome>()
    }

    let signalCrudUpload = BroadcastStream<Void>()
    let signalCrudUploadComplete = BroadcastStream<Void>()
    private let signalPendingCheckpointRequestWaitingForReady = BroadcastStream<Void>()
    private let pendingCheckpointRequests = Mutex(PendingCheckpointRequestsState())

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
            // A previous failure is checked again by the next
            // iteration, so it should not be replayed to new callers in the meantime.
            state.outcome = .pending
        }
    }

    /// Marks checkpoint processing as safe and resumes pending callers waiting to create request IDs.
    func markCheckpointsReady() {
        pendingCheckpointRequests.withLock { state in
            if case .ready = state.outcome {
                return
            }

            state.outcome = .ready
            // Dispatch while the state lock is held so a new affirmation cycle and its waiters
            // cannot observe this transition after the state has returned to pending.
            state.outcomeChanged.dispatch(event: .ready)
        }
    }

    /// Fails pending checkpoint requests and resumes callers blocked before ID allocation.
    func failPendingCheckpointRequests(_ error: any Error) {
        pendingCheckpointRequests.withLock { state in
            state.outcome = .failed(error)
            // Keep transition delivery atomic with the state update for the same reason as the
            // ready path above.
            state.outcomeChanged.dispatch(event: .failed(error))
        }
    }

    /// Permanently fails all pending checkpoint request creation waits after the owning sync client has stopped.
    ///
    /// Without this, a `requestCheckpoint()` caller racing a `disconnect()` would suspend forever:
    /// no further sync iteration exists to resume its waiter.
    func tearDown() {
        failPendingCheckpointRequests(CheckpointRequestError.notConnecting)
    }

    /// Waits until pending checkpoint requests can safely allocate IDs for the active connection.
    ///
    /// Registering a waiter here also wakes the download loop from its retry delay so connect-time
    /// validation can run promptly after a failed connection attempt.
    func waitForCheckpointRequestsReady(wakeDownloadLoop: Bool = true) async throws {
        enum WaitResult {
            case ready
            case failed(any Error)
            case waiting(AsyncStream<PendingCheckpointRequestsState.Outcome>)
        }

        while true {
            // AsyncStream.next() may return nil instead of throwing when cancelled.
            try Task.checkCancellation()

            // Subscribe while holding the state lock so a transition cannot be missed between
            // checking the outcome and registering for its next change.
            let result = pendingCheckpointRequests.withLock { state -> WaitResult in
                switch state.outcome {
                case .pending:
                    // Preserve the first transition observed by this one-shot waiter. A later
                    // state change must not replace the readiness result that originally woke it.
                    return .waiting(state.outcomeChanged.subscribe(bufferingPolicy: .bufferingOldest(1)))
                case .ready:
                    return .ready
                case .failed(let error):
                    return .failed(error)
                }
            }

            switch result {
            case .ready:
                return
            case .failed(let error):
                throw error
            case .waiting(let outcomeChanged):
                if wakeDownloadLoop {
                    signalPendingCheckpointRequestWaitingForReady.dispatch(event: ())
                }

                var iterator = outcomeChanged.makeAsyncIterator()
                guard let outcome = await iterator.next() else {
                    try Task.checkCancellation()
                    continue
                }

                switch outcome {
                case .pending:
                    continue
                case .ready:
                    return
                case .failed(let error):
                    throw error
                }
            }
        }
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

        // Subscribe before starting the task group so a waiter registering in the meantime is
        // observed by the iteration below instead of being missed while the group starts up.
        let pendingRequest = signalPendingCheckpointRequestWaitingForReady.subscribe(
            bufferingPolicy: .bufferingNewest(1)
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await sleepForSeconds(seconds: seconds)
            }

            group.addTask {
                var iterator = pendingRequest.makeAsyncIterator()
                _ = await iterator.next()
            }

            let _ = try await group.next()
            group.cancelAll()
            // Cancelling a task while AsyncStream.next() is awaiting a value terminates the
            // stream, but next() may return nil instead of throwing. Propagate parent cancellation.
            try Task.checkCancellation()
        }
    }
}
