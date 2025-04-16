import Foundation

actor LockActor {
    private var isLocked = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    func withLock<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await waitUntilUnlocked()

        isLocked = true
        defer { unlockNext() }

        try Task.checkCancellation() // cancellation check after acquiring lock
        return try await operation()
    }

    private func waitUntilUnlocked() async throws {
        if !isLocked { return }

        let id = UUID()

        // Use withTaskCancellationHandler to manage cancellation
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            // Cancellation logic: remove the waiter when cancelled
            Task {
                await self.removeWaiter(id: id)
            }
        }
    }

    private func removeWaiter(id: UUID) async {
        // Safely remove the waiter from the actor's waiters list
        waiters.removeAll { $0.id == id }
    }

    private func unlockNext() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume()
        } else {
            isLocked = false
        }
    }
}
