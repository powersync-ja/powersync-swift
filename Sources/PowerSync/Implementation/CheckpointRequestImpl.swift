final class CheckpointRequestImpl: CheckpointRequest {
    private let requestId: Int64
    private let syncClient: StreamingSyncClient

    init(requestId: Int64, syncClient: StreamingSyncClient) {
        self.requestId = requestId
        self.syncClient = syncClient
    }

    var isSynced: Bool {
        syncClient.isCheckpointRequestApplied(requestId)
    }

    func waitForSync() async throws {
        try await syncClient.waitForCheckpointRequest(requestId)
    }
}
