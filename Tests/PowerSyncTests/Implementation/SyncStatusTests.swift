import AsyncAlgorithms
import Foundation
@testable import PowerSync
import Testing

struct SyncStatusTests {
    @Test @MainActor func canObserve() async throws {
        let status = SwiftSyncStatus()
        let observable = status.observable
        #expect(observable === status.observable, "observable instances should be re-used")
        
        var hasDownloadError = false
        let updatesChannel = AsyncChannel<Void>()

        let observeStatus: () -> Void = {
            hasDownloadError = observable.downloadError != nil
        }

        withObservationTracking {
            observeStatus()
        } onChange: {
            Task { await updatesChannel.send(()) }
        }
        
        var updates = updatesChannel.makeAsyncIterator()
        #expect(!hasDownloadError)
        
        status.mutateStatus { $0.internalDownloadError = PowerSyncError.operationFailed(message: "test error", underlyingError: nil) }
        await updates.next()
    }
}
