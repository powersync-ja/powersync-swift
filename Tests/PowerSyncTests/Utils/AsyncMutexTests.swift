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
            }
        }
        let third = Task {
            let grant = try await semaphore.acquire(count: 1)
            try #require(grant.acquiredItems[0] == "a")
            return
        }
        
        await Task.yield()
        second.cancel()
        
        let _ = consume grant1
        let _ = await (second.result, third.result)
    }
}
