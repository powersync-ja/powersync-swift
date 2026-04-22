import Foundation

// Throttled async sequences that drop events emitted during a timeout.
// Inspired from https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncThrottleSequence.swift,
// but with changes to support older platforms.
struct AsyncThrottleSequence<Base: AsyncSequence & Sendable>: AsyncSequence where Base.Element == () {
    typealias AsyncIterator = IteratorImpl
    typealias Element = ()

    private let inner: Base
    private let duration: TimeInterval
    
    init(inner: Base, duration: TimeInterval) {
        self.inner = inner
        self.duration = duration
    }
    
    func makeAsyncIterator() -> IteratorImpl {
        IteratorImpl(duration: duration, inner: inner)
    }
    
    final class IteratorImpl: AsyncIteratorProtocol, Sendable {
        fileprivate let duration: TimeInterval
        private let state: LockedThrottleSequenceState
        let pollTask: Task<(), any Error>

        init(duration: TimeInterval, inner: Base) {
            self.duration = duration
            let state = LockedThrottleSequenceState()
            self.pollTask = Task {
                defer { state.state.withLock { $0.transitionToDone() } }
                
                do {
                    for try await event in inner {
                        state.state.withLock { $0.markHasEvent(event: .success(event)) }
                    }
                } catch {
                    state.state.withLock { $0.markHasEvent(event: .failure(error)) }
                }
            }
            
            self.state = state
        }
        
        func next() async throws -> ()? {
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        state.state.withLock { $0.registerListener(continuation) }
                    }
                },
                onCancel: {
                    pollTask.cancel()
                    state.state.withLock {
                        if case .waitingForUpstream(let continuation) = $0 {
                            continuation.resume(returning: nil)
                        }
                        $0 = .done
                    }
                }
            )
        }
    }
}

private final class LockedThrottleSequenceState: Sendable {
    let state = Mutex(ThrottleSequenceState.idle)
}

private enum ThrottleSequenceState {
    /// No one waiting on next(), no pending emit either.
    case idle
    /// We're waiting in next() for an upstream emission.
    case waitingForUpstream(CheckedContinuation<()?, any Error>)
    /// We have an upstream emission that has not yet been sent (due to backpressure or throttle).
    case hasPendingEvent(Result<(), any Error>)
    case done
    
    mutating func registerListener(_ continuation: CheckedContinuation<()?, any Error>) {
        switch self {
        case .idle:
            self = .waitingForUpstream(continuation)
        case .waitingForUpstream(_):
            fatalError("Async throttle sequence has two concurrent listeners?!")
        case .hasPendingEvent(let pending):
            continuation.resume(with: pending.map { _ in () })
            self = .idle
        case .done:
            continuation.resume(returning: nil)
        }
    }
    
    mutating func markHasEvent(event: Result<(), any Error>) {
        if case let .waitingForUpstream(continuation) = self {
            continuation.resume(with: event.map { _ in () })
            self = .idle
        } else {
            self = .hasPendingEvent(event)
        }
    }
    
    mutating func transitionToDone() {
        if case let .waitingForUpstream(continuation) = self {
            continuation.resume(returning: nil)
        }
        self = .done
    }
}
