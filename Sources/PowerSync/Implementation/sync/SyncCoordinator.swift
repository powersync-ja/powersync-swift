/// Manages a connection task for a PowerSync database.
actor SyncCoordinator {
    private var activeSync: Task<Void, any Error>?
    
    func connect(db: KotlinPowerSyncDatabaseImpl, connector: PowerSyncBackendConnectorProtocol, options: ConnectOptions, client: HttpClient) async {
        if let task = activeSync {
            await self.finishSyncTask(task: task)
        }
        
        var client = client
        if let logger = options.clientConfiguration?.requestLogger {
            client = LoggingClient(inner: client, logger: logger)
        }

        let sync = StreamingSyncClient(db: db, connector: connector, httpClient: client, options: options)
        activeSync = sync.run()
    }
    
    func disconnect() async {
        guard let task = activeSync else {
            return // Not connecteed
        }
        
        await self.finishSyncTask(task: task)
    }
    
    /// Executes an inner function, but only if no connection is active or scheduled.
    func guardNotConnected<T>(inner: () async throws -> T, ifConnected: () throws -> Never) async rethrows -> T {
        if activeSync == nil {
            return try await inner();
        } else {
            try ifConnected()
        }
    }
    
    private func finishSyncTask(task: Task<Void, any Error>) async {
        self.activeSync = nil
        task.cancel()
        do {
            try await task.value
        } catch {
            // Ignore here, the sync task itself handles errors by retrying.
        }
    }
}
