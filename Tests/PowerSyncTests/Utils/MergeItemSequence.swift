import AsyncAlgorithms
@testable import PowerSync
import Testing

@Suite
struct MergeItemSequenceTest {
    private let source = AsyncThrowingChannel<(), any Error>()

    private func generateMerged() -> MergeItemSequence<AsyncThrowingChannel<(), any Error>> {
        MergeItemSequence(inner: source)
    }

    @Test func canReceiveItem() async throws {
        let items = generateMerged().makeAsyncIterator()
        async let didReceive = items.next()
        await source.send(())
        try #require(await didReceive)
    }

    @Test @MainActor func mergesItems() async throws {
        let items = generateMerged().makeAsyncIterator()
        await source.send(())
        await source.send(())
        await source.send(())

        async let firstItem = items.next()
        try #require(await firstItem)
        
        var hasSecondItem = false
        let secondTask = Task {
            try #require(await items.next())
            hasSecondItem = true
        }
        
        try #require(!hasSecondItem)
        await Task.yield()
        try #require(!hasSecondItem)
        
        await source.send(())
        try await secondTask.value
    }

    @Test func reportsErrors() async throws {
        let items = generateMerged().makeAsyncIterator()
        await #expect(throws: PowerSyncError.self) {
            async let firstItem = items.next()
            await source.fail(PowerSyncError.operationFailed(message: "error for test"))

            try await firstItem
        }
    }

    @Test func forwardsClose() async throws {
        let items = generateMerged().makeAsyncIterator()
        await source.send(())
        try #require(try await items.next())
        source.finish()
        try #require(try await items.next() == nil)
        try await items.pollTask.value
    }
    
    @Test func closesOnDrop() async throws {
        let task: Task<Void, any Error>
        do {
            let items = generateMerged().makeAsyncIterator()
            task = items.pollTask
        }

        try await task.value
    }
}
