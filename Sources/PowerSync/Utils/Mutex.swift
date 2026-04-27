import Darwin

/// A backport of `Mutex` from the `Synchronization` module.
struct Mutex<T: ~Copyable>: @unchecked Sendable, ~Copyable {
    // We have to use pointer indirection to ensure the os_unfair_lock_t has a stable address.
    private let osLock = os_unfair_lock_t.allocate(capacity: 1)
    // This is behind a pointer to silence a compiler error about mutating its contents in a non-mutating func.
    private let value: UnsafeMutablePointer<T> = .allocate(capacity: 1)
    
    init(_ value: consuming T) {
        self.osLock.initialize(to: os_unfair_lock())
        self.value.initialize(to: value)
    }
    
    deinit {
        self.osLock.deinitialize(count: 1)
        self.osLock.deallocate()
        self.value.deinitialize(count: 1)
        self.value.deallocate()
    }
    
    func withLock<R: ~Copyable>(_ action: (_ value: inout T) throws -> R) rethrows -> R {
        os_unfair_lock_lock(self.osLock)
        defer { os_unfair_lock_unlock(self.osLock) }
        
        return try action(&value.pointee)
    }
}
