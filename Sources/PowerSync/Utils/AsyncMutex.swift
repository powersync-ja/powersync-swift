/// An asynchronous mutex implemented as a simple actor.
actor AsyncMutex<T: ~Copyable> {
    var inner: T

    init(_ inner: consuming sending T) {
        self.inner = inner
    }

    func withMutex<R>(callback: (_ element: inout T) throws -> R) rethrows -> R {
        try callback(&inner)
    }
}
