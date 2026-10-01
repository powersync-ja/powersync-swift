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
        await source.fail(PowerSyncError.operationFailed(message: "error for test"))
        await #expect(throws: PowerSyncError.self) { try await items.next() }
    }

    @Test func reportsErrorsToSlowListener() async throws {
        let items = generateMerged().makeAsyncIterator()
        await source.fail(PowerSyncError.operationFailed(message: "error for test"))
        for _ in 0...100 {
            await Task.yield()
        }
        await #expect(throws: PowerSyncError.self) { try await items.next() }
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

    /// A cancellation of `next()` racing an upstream event or completion must never deadlock:
    /// cancelling holds the task's status-record lock and runs `onCancel` (state lock), while
    /// the poll task resumes the same task's continuation — which needs that status-record lock.
    @Test(.timeLimit(.minutes(1))) func cancellingWhileUpstreamEmitsNeverDeadlocks() async throws {
        for round in 0..<3000 {
            let source = AsyncThrowingChannel<(), any Error>()
            let items = MergeItemSequence(inner: source).makeAsyncIterator()
            let waiter = Task { try await items.next() }
            if round % 2 == 0 { await Task.yield() }
            async let emitted: Void = source.send(())
            waiter.cancel()
            source.finish()
            _ = try? await waiter.value
            await emitted
        }
    }
}
