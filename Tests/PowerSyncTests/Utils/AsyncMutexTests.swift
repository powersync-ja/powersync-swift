@testable import PowerSync
import Testing

@Suite
struct AsyncSemaphoreTests {
    @Test func dispatchesItemsInOrder() async throws {
        let semaphore = AsyncSemaphore(from: ["a", "b", "c"])

        let grant1 = try await semaphore.acquire(count: 1)
        let grant2 = try await semaphore.acquire(count: 1)
        let grant3 = try await semaphore.acquire(count: 1)

        try #require(grant1.acquiredItems[0] == "a")
        try #require(grant2.acquiredItems[0] == "b")
        try #require(grant3.acquiredItems[0] == "c")
    }
    
    @Test @MainActor func returnsReleasedItemsToWaiters() async throws {
        let semaphore = AsyncSemaphore(from: ["x"])

        let grant1 = try await semaphore.acquire(count: 1)
        var hasSecond = false

        let grant2 = Task {
            let grant = try await semaphore.acquire(count: 1)
            hasSecond = true
            return grant.acquiredItems[0]
        }

        try #require(!hasSecond)
        let _ = consume grant1
        try #require(try await grant2.value == "x")
        try #require(hasSecond)
    }
    
    @Test @MainActor func canAcquireMultiple() async throws {
        let semaphore = AsyncSemaphore(from: ["a", "b", "c"])
        let grant1 = try await semaphore.acquire(count: 1)
        let grant2 = try await semaphore.acquire(count: 1)

        var hasAll = false
        let acquireAllTask = Task {
            let _ = try await semaphore.acquire(count: 3)
            hasAll = false
        }

        await Task.yield()
        try #require(!hasAll)

        let _ = consume grant1
        await Task.yield()
        try #require(!hasAll) // Still waiting for item2

        let _ = consume grant2
        let _ = await acquireAllTask.result
    }
    
    @Test func canReturnMultiple() async throws {
        let semaphore = AsyncSemaphore(from: ["a", "b"])

        let grantAll = try await semaphore.acquire(count: 2)

        let hasOther = Task {
            let grant = try await semaphore.acquire(count: 1)
            try #require(grant.acquiredItems[0] == "b") // We return the last item first
            
            let anotherGrant = try await semaphore.acquire(count: 1)
            try #require(anotherGrant.acquiredItems[0] == "a")
            return true
        }

        let _ = consume grantAll
        let _ = try await hasOther.value
    }
    
    @Test func canAbort() async throws {
        let semaphore = AsyncSemaphore(from: ["a"])

        let grant1 = try await semaphore.acquire(count: 1)
        let second = Task {
            await #expect(throws: CancellationError.self) {
                let _ = try await semaphore.acquire(count: 1)
                print("has items")
            }
        }
        let third = Task {
            let grant = try await semaphore.acquire(count: 1)
            try #require(grant.acquiredItems[0] == "a")
            return
        }

        await Task.yield()
        second.cancel()
        let _ = await second.result

        let _ = consume grant1
        try (await third.result).get()
    }
    
    @Test func canAbortPartial() async throws {
        let semaphore = AsyncSemaphore(from: ["a", "b"])
        let grant1 = try await semaphore.acquire(count: 1)
        let second = Task {
            await #expect(throws: CancellationError.self) {
                let _ = try await semaphore.acquire(count: 2)
            }
        }
        let third = Task {
            let grant = try await semaphore.acquire(count: 2)
            try #require(grant.acquiredItems[0] == "b")
            try #require(grant.acquiredItems[1] == "a")
            return
        }

        await Task.yield()
        // At this point, second obtained value b from the semaphore, but it's still waiting
        // for the second node. Aborting it should b into the semaphore.
        second.cancel()
        let _ = await second.result
        let _ = consume grant1
        try (await third.result).get()
    }

    /// A waiter cancelled at the moment another task returns the item it waits for must not
    /// deadlock. The runtime holds the cancelled task's status-record lock while its
    /// cancellation handler takes the semaphore lock; the returning task must therefore not
    /// resume the waiter while it holds that same lock.
    @Test func cancellationCanRaceWithReturn() async throws {
        let semaphore = AsyncSemaphore(from: ["a"])
        for _ in 0..<1_000 {
            let (release, releaser) = AsyncStream<Void>.makeStream()
            let holder = Task {
                let grant = try await semaphore.acquire(count: 1)
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
                let _ = consume grant
            }
            await Task.yield()
            let waiter = Task {
                let _ = try await semaphore.acquire(count: 1)
            }
            await Task.yield()

            await withTaskGroup(of: Void.self) { group in
                group.addTask { releaser.finish() }
                group.addTask { waiter.cancel() }
            }

            _ = await waiter.result
            _ = try await holder.value
        }
    }
}
