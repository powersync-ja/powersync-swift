import Dispatch
import Synchronization

/// Bridges the synchronous, throwing world of `DataStore` callbacks to the async PowerSync API.
///
/// `SwiftData.DataStore` requires synchronous `fetch`/`save` implementations while every
/// PowerSync database operation is `async`. The bridge runs the async body and blocks the
/// calling thread until it completes.
///
/// Safety contract:
/// - The async body must never await work isolated to the blocked caller (for example, a
///   `@MainActor` function when the caller is the main thread). PowerSync operations run on
///   GCD queues and never hop back to the caller, so they satisfy this.
/// - SwiftData may invoke the store *from* a cooperative-pool thread (any `ModelContext`
///   used inside a task), so the bridge must not require a cooperative-pool thread to make
///   progress. The body therefore runs with a dedicated `TaskExecutor` backed by a private
///   GCD queue: neither the body nor its continuations ever wait for the cooperative pool,
///   which keeps the bridge deadlock-free even when every pool thread is blocked inside it.
///   This is validated by the pool-saturation stress test.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
enum AsyncBridge {
    /// Runs every bridged body and its continuations on GCD worker threads, which the system
    /// can grow when they block, unlike the fixed-width cooperative pool.
    private final class BridgeExecutor: TaskExecutor {
        private let queue = DispatchQueue(
            label: "com.powersync.swiftdata.async-bridge",
            qos: .userInitiated,
            attributes: .concurrent
        )

        func enqueue(_ job: consuming ExecutorJob) {
            let unownedJob = UnownedJob(job)
            let unownedExecutor = asUnownedTaskExecutor()
            queue.async {
                unownedJob.runSynchronously(on: unownedExecutor)
            }
        }
    }

    private static let executor = BridgeExecutor()

    /// Runs `body` and blocks the current thread until it finishes, returning its result.
    static func blocking<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<Result<T, any Error>?>(nil)
        Task(executorPreference: executor, priority: .userInitiated) {
            let outcome: Result<T, any Error>
            do {
                outcome = try await .success(body())
            } catch {
                outcome = .failure(error)
            }
            result.withLock { $0 = outcome }
            semaphore.signal()
        }
        semaphore.wait()
        guard let outcome = result.withLock({ $0 }) else {
            preconditionFailure("AsyncBridge task signalled without storing a result")
        }
        return try outcome.get()
    }
}
