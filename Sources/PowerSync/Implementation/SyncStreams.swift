import Foundation

final class StreamTracker: Sendable {
    // For each active stream key, how many StreamSubscription instances are active in that key.
    private let groups: Mutex<Dictionary<StreamKey, Int>> = Mutex([:])
    let streamsChanged = BroadcastStream<[StreamKey]>()
    
    var currentStreams: [StreamKey] {
        groups.withLock { groups in Array(groups.keys) }
    }
    
    private func markActiveStreamsHaveChanged() {
        streamsChanged.dispatch(event: currentStreams)
    }
    
    fileprivate func subscriptionsCommand(db: PowerSyncDatabaseImpl, request: RustSubscriptionChangeRequest) async throws {
        let _ = try await db.writeTransaction { tx in
            let payload = String(data: try StreamingSyncClient.jsonEncoder.encode(request), encoding: .utf8)
            try tx.execute(sql: "SELECT powersync_control(?, ?)", parameters: [
                "subscriptions",
                payload
            ])
        }
        
        try await db.resolveOfflineSyncStatusIfNotConnected()
    }
    
    fileprivate func subscribe(db: PowerSyncDatabaseImpl, stream: PendingSyncStream, ttl: TimeInterval?, priority: BucketPriority?) async throws -> SyncSubscriptionImplementation {
        let key = stream.key
        try await subscriptionsCommand(
            db: db,
            request: .subscribe(
                stream: key,
                ttl: ttl.map { Int64($0) },
                priority: priority
            )
        )
        
        let didCreateGroup = groups.withLock { groups in
            if let existingCount = groups[key] {
                groups[key] = existingCount + 1
                return false
            } else {
                groups[key] = 1
                return true
            }
        }
        
        if didCreateGroup {
            markActiveStreamsHaveChanged()
        }
        
        return SyncSubscriptionImplementation(db: db, key: key)
    }
    
    fileprivate func removeStreamGroup(key: StreamKey) {
        let _ = groups.withLock { groups in groups.removeValue(forKey: key) }
        markActiveStreamsHaveChanged()
    }
    
    fileprivate func decrementRefCount(key: StreamKey) {
        let didChangeStreams = groups.withLock { groups in
            if let count = groups[key] {
                if count == 1 {
                    groups.removeValue(forKey: key)
                    return true
                } else {
                    groups[key] = count - 1
                }
            }
            
            return false
        }
        if didChangeStreams {
            markActiveStreamsHaveChanged()
        }
    }
}

/// A Sync Stream that can be subscribed to.
struct PendingSyncStream: SyncStream {
    let db: PowerSyncDatabaseImpl
    let name: String
    let parameters: JsonParam?
    
    var key: StreamKey {
        StreamKey(name: name, params: parameters)
    }
    
    func subscribe(ttl: TimeInterval?, priority: BucketPriority?) async throws -> any SyncStreamSubscription {
        return try await db.syncCoordinator.streams.subscribe(db: db, stream: self, ttl: ttl, priority: priority)
    }
    
    func unsubscribeAll() async throws {
        let tracker = db.syncCoordinator.streams
        let key = self.key
        tracker.removeStreamGroup(key: key)
        try await tracker.subscriptionsCommand(db: db, request: .unsubscribe(key))
    }
}

final class SyncSubscriptionImplementation: SyncStreamSubscription {
    private let db: PowerSyncDatabaseImpl
    private let key: StreamKey

    init(db: PowerSyncDatabaseImpl, key: StreamKey) {
        self.db = db
        self.key = key
    }
    
    var name: String {
        key.name
    }

    var parameters: JsonParam? {
        key.params
    }

    func waitForFirstSync() async throws {
        await db.syncStatus.waitFor { status in status.forStream(stream: self)?.subscription.hasSynced == true }
    }
    
    func unsubscribe() async throws {
        // We don't need to do anything here, we'll unsubscribe on deinit instead.
    }
    
    deinit {
        db.syncCoordinator.streams.decrementRefCount(key: key)
    }
}

private enum RustSubscriptionChangeRequest: Encodable {
    case subscribe(
        stream: StreamKey,
        ttl: Int64? = nil,
        priority: BucketPriority? = nil
    )
    case unsubscribe(StreamKey)
    
    enum CodingKeys: CodingKey {
        case subscribe
        case unsubscribe
    }
    
    enum SubscribeCodingKeys: CodingKey {
        case stream
        case ttl
        case priority
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .subscribe(let stream, let ttl, let priority):
            var nestedContainer = container.nestedContainer(keyedBy: RustSubscriptionChangeRequest.SubscribeCodingKeys.self, forKey: .subscribe)
            try nestedContainer.encode(stream, forKey: RustSubscriptionChangeRequest.SubscribeCodingKeys.stream)
            try nestedContainer.encodeIfPresent(ttl, forKey: RustSubscriptionChangeRequest.SubscribeCodingKeys.ttl)
            try nestedContainer.encodeIfPresent(priority, forKey: RustSubscriptionChangeRequest.SubscribeCodingKeys.priority)
        case .unsubscribe(let key):
            try container.encode(key, forKey: .unsubscribe)
        }
    }
}
