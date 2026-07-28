import Foundation

/// Manages a connection task for a PowerSync database.
actor SyncCoordinator {
    nonisolated let streams = StreamTracker()
    private var activeSync: Task<Void, any Error>?
    /// Mutex-backed instead of actor-isolated so ``syncClient`` can be read synchronously.
    /// Only mutated from the actor.
    private nonisolated let currentClient = Mutex<StreamingSyncClient?>(nil)

    /// A snapshot of the sync client for the active connection, if any.
    nonisolated var syncClient: StreamingSyncClient? {
        currentClient.withLock { $0 }
    }

    func connect(db: PowerSyncDatabaseImpl, connector: PowerSyncBackendConnectorProtocol, options: ConnectOptions, client: HttpClient?) async {
        if let task = activeSync {
            await self.finishSyncTask(task: task)
        }

        func defaultHttpClient() -> HttpClient {
            let session = options.clientConfiguration?.urlSession ?? .shared
            return session.client
        }

        let client = client ?? defaultHttpClient()
        let sync = StreamingSyncClient(db: db, connector: connector, httpClient: client, options: options)
        currentClient.withLock { $0 = sync }
        activeSync = sync.run()
    }
    
    func disconnect() async {
        guard let task = activeSync else {
            return // Not connected
        }
        
        await self.finishSyncTask(task: task)
    }
    
    /// Runs ``Self/disconnect`` and `action` in a single actor message lock.
    func disconnectAndThen<T>(action: () async throws -> T) async rethrows -> T {
        await disconnect()
        return try await action()
    }
    
    /// Executes an inner function, but only if no connection is active or scheduled.
    func guardNotConnected<T, Failure: Error>(
        inner: () async throws(Failure) -> T,
        ifConnected: (StreamingSyncClient) async throws(Failure) -> T
    ) async throws(Failure) -> T {
        guard activeSync != nil, let sync = syncClient else {
            return try await inner()
        }
        return try await ifConnected(sync)
    }

    /// Requests a checkpoint while serializing the active-client check with connect and disconnect.
    func requestCheckpoint() async throws(CheckpointRequestError) -> any CheckpointRequest {
        guard activeSync != nil, let sync = syncClient else {
            throw .notConnecting
        }
        return try await sync.requestCheckpoint()
    }

    private func finishSyncTask(task: Task<Void, any Error>) async {
        self.activeSync = nil
        currentClient.withLock { $0 = nil }
        task.cancel()
        do {
            try await task.value
        } catch {
            // Ignore here, the sync task itself handles errors by retrying.
        }
    }
}
