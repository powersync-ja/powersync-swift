actor SyncCoordinator {
    private var activeSync: Task<Void, any Error>?
    
    func connect(db: KotlinPowerSyncDatabaseImpl, connector: PowerSyncBackendConnectorProtocol, options: ConnectOptions) async {
        if let task = activeSync {
            await self.finishSyncTask(task: task)
        }
        
        let sync = StreamingSyncClient(db: db, connector: connector)
        activeSync = sync.run()
    }
    
    func disconnect() async {
        guard let task = activeSync else {
            return // Not connecteed
        }
        
        await self.finishSyncTask(task: task)
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
