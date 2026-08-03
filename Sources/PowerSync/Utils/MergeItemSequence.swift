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
                        state.inner.withLock { $0.markHasEvent() }
                    }

                    state.inner.withLock { $0.transitionToDone() }
                } catch {
                    state.inner.withLock { $0.markFailed(error: error) }
                }
            }

            self.state = state
        }

        func next() async throws -> ()? {
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        state.inner.withLock { $0.registerListener(continuation) }
                    }
                },
                onCancel: {
                    pollTask.cancel()
                    state.inner.withLock {
                        if case .waitingForUpstream(let continuation) = $0 {
                            continuation.resume(returning: nil)
                        }
                        $0 = .done
                    }
                }
            )
        }
        
        deinit {
            self.pollTask.cancel()
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
    
    mutating func registerListener(_ continuation: CheckedContinuation<()?, any Error>) {
        switch self {
        case .idle:
            self = .waitingForUpstream(continuation)
        case .waitingForUpstream(_):
            fatalError("Async throttle sequence has two concurrent listeners?!")
        case .hasPendingEvent:
            continuation.resume(returning: ())
            self = .idle
        case .failure(let error):
            continuation.resume(throwing: error)
            self = .done
        case .done:
            continuation.resume(returning: nil)
        }
    }

    mutating func markHasEvent() {
        if case let .waitingForUpstream(continuation) = self {
            continuation.resume(returning: ())
            self = .idle
        } else {
            self = .hasPendingEvent
        }
    }

    mutating func markFailed(error: any Error) {
        if case let .waitingForUpstream(continuation) = self {
            continuation.resume(throwing: error)
            self = .done
        } else {
            self = .failure(error)
        }
    }

    mutating func transitionToDone() {
        if case let .waitingForUpstream(continuation) = self {
            continuation.resume(returning: nil)
        }
        self = .done
    }
}
