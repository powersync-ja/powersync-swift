
internal actor LockActor {
    private var isLocked = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    
    func withLock<T>(_ execute: @Sendable () async throws -> T) async throws -> T {
        if isLocked {
            await withCheckedContinuation { continuation in
                queue.append(continuation)
            }
        }
    
        isLocked = true
        defer { unlockNext() }
        return try await execute()
    }

    private func unlockNext() {
        if let next = queue.first {
            queue.removeFirst()
            next.resume(returning: ())
        } else {
            isLocked = false
        }
    }
}
