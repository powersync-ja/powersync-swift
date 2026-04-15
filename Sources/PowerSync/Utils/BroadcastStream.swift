import Synchronization

final class BroadcastStream<T: Sendable>: Sendable {
    private let listeners: Mutex<Set<BroadcastStreamListener<T>>> = Mutex([])
    
    private func register(continuation: AsyncStream<T>.Continuation) {
        let listener = BroadcastStreamListener(continuation: continuation)
        let _ = listeners.withLock { $0.insert(listener) }

        continuation.onTermination = { @Sendable [weak self] _ in
            let _ = self?.listeners.withLock {
                $0.remove(listener)
            }
        }
    }
    
    func dispatch(event: T) {
        let listeners = self.listeners.withLock { Array($0) }
        for listener in listeners {
            listener.continuation.yield(event)
        }
    }

    func subscribe(bufferingPolicy: AsyncStream<T>.Continuation.BufferingPolicy = .unbounded) -> AsyncStream<T> {
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            self.register(continuation: continuation)
        }
    }
}

final private class BroadcastStreamListener<T>: Sendable, Hashable {
    let continuation: AsyncStream<T>.Continuation
    init(continuation: AsyncStream<T>.Continuation) {
        self.continuation = continuation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    
    static func == (lhs: BroadcastStreamListener<T>, rhs: BroadcastStreamListener<T>) -> Bool {
        lhs === rhs
    }
}
