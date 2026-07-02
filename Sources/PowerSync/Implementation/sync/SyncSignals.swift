import Foundation

/// Allows the concurrent upload and download tasks to communicate.
///
/// The download task might request a CRUD upload when a checkpoint can't be applied due to local
/// data, and the upload task needs to signal completions so downloads can retry applying it.
final class SyncSignals: Sendable {
    private struct CheckpointRequestsState {
        var isReady = false
        var failure: (any Error)?
        var waiters: [AsyncThrowingStream<Void, any Error>.Continuation] = []
    }

    let signalCrudUpload = BroadcastStream<Void>()
    let signalCrudUploadComplete = BroadcastStream<Void>()
    private let signalCheckpointRequestWaitingForReady = BroadcastStream<Void>()
    private let shouldSkipRetryDelay = Mutex(false)
    private let checkpointRequests = Mutex(CheckpointRequestsState())

    func triggerAsyncCrudUpload() {
        self.signalCrudUpload.dispatch(event: ())
    }

    func notifyCrudUploadComplete() {
        self.signalCrudUploadComplete.dispatch(event: ())
    }

    func invalidateCheckpointRequests() {
        checkpointRequests.withLock { state in
            state.isReady = false
        }
    }

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
