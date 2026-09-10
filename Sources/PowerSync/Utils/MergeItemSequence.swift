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
                        let resolution = state.inner.withLock { $0.markHasEvent() }
                        resolution.resume()
                    }

                    let resolution = state.inner.withLock { $0.transitionToDone() }
                    resolution.resume()
                } catch {
                    let resolution = state.inner.withLock { $0.markFailed(error: error) }
                    resolution.resume()
                }
            }

            self.state = state
        }

        func next() async throws -> ()? {
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        let resolution = state.inner.withLock { $0.registerListener(continuation) }
                        resolution.resume()
                    }
                },
                onCancel: {
                    pollTask.cancel()
                    let resolution = state.inner.withLock { $0.cancel() }
                    resolution.resume()
                }
            )
        }
        
        deinit {
            self.pollTask.cancel()
        }
    }
}

private enum MergeSequenceResolution {
    case none
    case success(CheckedContinuation<()?, any Error>, ()?)
    case failure(CheckedContinuation<()?, any Error>, any Error)

    func resume() {
        switch self {
        case .none:
            break
        case let .success(continuation, value):
            continuation.resume(returning: value)
        case let .failure(continuation, error):
            continuation.resume(throwing: error)
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
    
    mutating func registerListener(_ continuation: CheckedContinuation<()?, any Error>) -> MergeSequenceResolution {
        switch self {
        case .idle:
            self = .waitingForUpstream(continuation)
            return .none
        case .waitingForUpstream(_):
            fatalError("Async throttle sequence has two concurrent listeners?!")
        case .hasPendingEvent:
            self = .idle
            return .success(continuation, ())
        case .failure(let error):
            self = .done
            return .failure(continuation, error)
        case .done:
            return .success(continuation, nil)
        }
    }

    mutating func markHasEvent() -> MergeSequenceResolution {
        switch self {
        case let .waitingForUpstream(continuation):
            self = .idle
            return .success(continuation, ())
        case .idle, .hasPendingEvent:
            self = .hasPendingEvent
            return .none
        case .failure, .done:
            return .none
        }
    }

    mutating func markFailed(error: any Error) -> MergeSequenceResolution {
        switch self {
        case let .waitingForUpstream(continuation):
            self = .done
            return .failure(continuation, error)
        case .idle, .hasPendingEvent, .failure:
            self = .failure(error)
            return .none
        case .done:
            return .none
        }
    }

    mutating func transitionToDone() -> MergeSequenceResolution {
        if case let .waitingForUpstream(continuation) = self {
            self = .done
            return .success(continuation, nil)
        }
        self = .done
        return .none
    }

    mutating func cancel() -> MergeSequenceResolution {
        if case let .waitingForUpstream(continuation) = self {
            self = .done
            return .success(continuation, nil)
        }
        self = .done
        return .none
    }
}
