import Combine
import Foundation
import PowerSyncKotlin

final class KotlinSyncStatus: KotlinSyncStatusDataProtocol, SyncStatus {
    private let baseStatus: PowerSyncKotlin.SyncStatus

    var base: PowerSyncKotlin.SyncStatusData {
        baseStatus
    }

    init(baseStatus: PowerSyncKotlin.SyncStatus) {
        self.baseStatus = baseStatus
    }

    func asFlow() -> AsyncStream<any SyncStatusData> {
        AsyncStream<any SyncStatusData>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Create an outer task to monitor cancellation
            let task = Task {
                do {
                    // Watching for changes in the database
                    for try await value in baseStatus.asFlow() {
                        // Check if the outer task is cancelled
                        try Task.checkCancellation() // This checks if the calling task was cancelled

                        continuation.yield(
                            KotlinSyncStatusData(base: value)
                        )
                    }

                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }

            // Propagate cancellation from the outer task to the inner task
            continuation.onTermination = { @Sendable _ in
                task.cancel() // This cancels the inner task when the stream is terminated
            }
        }
    }
}
