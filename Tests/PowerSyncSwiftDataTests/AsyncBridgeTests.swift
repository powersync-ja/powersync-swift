import Dispatch
import Foundation
@testable import PowerSyncSwiftData
import Synchronization
import Testing

/// Validates the synchronous-over-async bridge that `fetch`/`save` rely on: results and
/// errors propagate, and the bridge cannot deadlock regardless of which thread SwiftData
/// invokes the store from.
@Suite("AsyncBridge")
struct AsyncBridgeTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(1)))
    func returnsValuesAndPropagatesErrors() throws {
        let value = try AsyncBridge.blocking { () async throws -> Int in
            try await Task.sleep(nanoseconds: 1_000_000)
            return 42
        }
        #expect(value == 42)

        struct Boom: Error, Equatable {}
        #expect(throws: Boom.self) {
            try AsyncBridge.blocking { () async throws -> Void in
                throw Boom()
            }
        }
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(1)))
    func doesNotDeadlockFromManyGCDThreads() {
        // SwiftData calls fetch/save synchronously on whatever thread the app happens to
        // use; simulate a burst of simultaneous callers on GCD worker threads.
        let iterations = 64
        let completed = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let value = try? AsyncBridge.blocking { () async throws -> Int in
                try await Task.sleep(nanoseconds: 2_000_000)
                return 1
            }
            completed.withLock { $0 += value ?? 0 }
        }
        #expect(completed.withLock { $0 } == iterations)
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(1)))
    func doesNotDeadlockWhenCooperativePoolIsSaturated() async {
        // Worst case for a semaphore bridge: every cooperative-pool thread is blocked
        // inside the bridge while the bridged work itself still needs somewhere to run.
        // 4x the core count guarantees the pool is saturated with blocked callers, and the
        // bridged body suspends twice so its continuations also need somewhere to resume.
        let callers = max(8, ProcessInfo.processInfo.activeProcessorCount * 4)
        let total = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0 ..< callers {
                group.addTask {
                    (try? AsyncBridge.blocking { () async throws -> Int in
                        try await Task.sleep(nanoseconds: 2_000_000)
                        try await Task.sleep(nanoseconds: 2_000_000)
                        return 1
                    }) ?? 0
                }
            }
            return await group.reduce(0, +)
        }
        #expect(total == callers)
    }
}
