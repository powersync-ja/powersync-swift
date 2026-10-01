/// An ``AsyncSequence`` merging all items emitted between calls to ``AsyncIteratorProtocol/next``.
/// 
/// This is useful for sequences where we just want to know that an event has occurred, without needing
/// to know about the exact event. We use this internally to implement `watch()` queries with a throttle:
/// If any amount of events have occurred between throttled calls to `next()`, we want to dispatch a single
/// event.
struct MergeItemSequence<Base: AsyncSequence & Sendable>: AsyncSequence where Base.Element == () {
    typealias AsyncIterator = IteratorImpl
    typealias Element = ()

    private let inner: Base

    init(inner: Base) {
        self.inner = inner
    }

    func makeAsyncIterator() -> IteratorImpl {
        IteratorImpl(inner: self.inner)
    }

    private final class IteratorState: Sendable {
        let inner = Mutex(MergeSequenceState.idle)
    }

    final class IteratorImpl: AsyncIteratorProtocol, Sendable {
        private let state: IteratorState
        let pollTask: Task<(), any Error>

        init(inner: Base) {
            let state = IteratorState()
            self.pollTask = Task {
                do {
                    for try await _ in inner {
                        state.inner.withLock { $0.markHasEvent() }?.run()
                    }

                    state.inner.withLock { $0.transitionToDone() }?.run()
                } catch {
                    state.inner.withLock { $0.markFailed(error: error) }?.run()
                }
            }

            self.state = state
        }

        func next() async throws -> ()? {
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        state.inner.withLock { $0.registerListener(continuation) }?.run()
                    }
                },
                onCancel: {
                    pollTask.cancel()
                    let pending: PendingResume? = state.inner.withLock {
                        defer { $0 = .done }
                        if case .waitingForUpstream(let continuation) = $0 {
                            return PendingResume(continuation, .returning(nil))
                        }
                        return nil
                    }
                    pending?.run()
                }
            )
        }
        
        deinit {
            self.pollTask.cancel()
        }
    }
}

/// A continuation resumption decided under the state lock and performed AFTER it is released.
///
/// Resuming a continuation takes the resumed task's status-record lock, while a task
/// cancellation runs `next()`'s `onCancel` (which takes the state lock) WHILE holding that same
/// status-record lock. Resuming inside `withLock` therefore inverts the lock order against a
/// concurrent cancellation and can deadlock both threads, so every state transition only
/// returns the resumption and the caller runs it once the lock is dropped.
private struct PendingResume {
    enum Outcome {
        case returning(()?)
        case throwing(any Error)
    }

    let continuation: CheckedContinuation<()?, any Error>
    let outcome: Outcome

    init(_ continuation: CheckedContinuation<()?, any Error>, _ outcome: Outcome) {
        self.continuation = continuation
        self.outcome = outcome
    }

    func run() {
        switch outcome {
        case .returning(let value): continuation.resume(returning: value)
        case .throwing(let error): continuation.resume(throwing: error)
        }
    }
}

private enum MergeSequenceState {
    /// No one waiting on next(), no pending emit either.
    case idle
    /// We're waiting in next() for an upstream emission.
    case waitingForUpstream(CheckedContinuation<()?, any Error>)
    /// We have an upstream emission that has not yet been sent (due to backpressure or throttle).
    case hasPendingEvent
    /// Fetching from upstream failed.
    /// 
    /// For the task fetching events, this is a final state: Once errored, it will not emit any
    /// further events, and it won't set the state to `done` like it would if the source iterator
    /// had completed normally.
    /// 
    /// This exists as a separate state to ensure a subsequent call to `next()` can throw. Once
    /// the error was observed there, this state transitions to `done`.
    case failure(any Error)
    case done
    
    mutating func registerListener(_ continuation: CheckedContinuation<()?, any Error>) -> PendingResume? {
        switch self {
        case .idle:
            self = .waitingForUpstream(continuation)
            return nil
        case .waitingForUpstream(_):
            fatalError("Async throttle sequence has two concurrent listeners?!")
        case .hasPendingEvent:
            self = .idle
            return PendingResume(continuation, .returning(()))
        case .failure(let error):
            self = .done
            return PendingResume(continuation, .throwing(error))
        case .done:
            return PendingResume(continuation, .returning(nil))
        }
    }

    mutating func markHasEvent() -> PendingResume? {
        if case let .waitingForUpstream(continuation) = self {
            self = .idle
            return PendingResume(continuation, .returning(()))
        }
        self = .hasPendingEvent
        return nil
    }

    mutating func markFailed(error: any Error) -> PendingResume? {
        if case let .waitingForUpstream(continuation) = self {
            self = .done
            return PendingResume(continuation, .throwing(error))
        }
        self = .failure(error)
        return nil
    }

    mutating func transitionToDone() -> PendingResume? {
        defer { self = .done }
        if case let .waitingForUpstream(continuation) = self {
            return PendingResume(continuation, .returning(nil))
        }
        return nil
    }
}
