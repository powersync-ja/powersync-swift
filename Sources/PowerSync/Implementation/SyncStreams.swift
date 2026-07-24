import Foundation

final class StreamTracker: Sendable {
    private let groups: Mutex<ActiveStreamsState> = Mutex(ActiveStreamsState())

    /// Returns a snapshot of currently active streams, and a stream that will emit an event for all subsequent
    /// updates to the list of active streams.
    func observeActiveStreams() -> ([StreamKey], AsyncStream<[StreamKey]>) {
        groups.withLock { state in
            let subscription = state.streamsChanged.subscribe()
            return (state.activeStreams, subscription)
        }
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

        groups.withLock { state in state.addStream(key: key) }
        return SyncSubscriptionImplementation(db: db, key: key)
    }

    fileprivate func removeStreamGroup(key: StreamKey) {
        groups.withLock { state in state.removeStreamGroup(key: key) }
    }

    fileprivate func decrementRefCount(key: StreamKey) {
        groups.withLock { state in state.decrementRefCount(key: key) }
    }
}

fileprivate class ActiveStreamsState {
    // For each active stream key, how many StreamSubscription instances are active in that key.
    var groups: Dictionary<StreamKey, Int> = [:]
    let streamsChanged = BroadcastStream<[StreamKey]>()

    var activeStreams: [StreamKey] {
        Array(groups.keys)
    }

    private func emit() {
        streamsChanged.dispatch(event: activeStreams)
    }

    func addStream(key: StreamKey) {
        if let existingCount = groups[key] {
            groups[key] = existingCount + 1
        } else {
            groups[key] = 1
            emit()
        }
    }

    func removeStreamGroup(key: StreamKey) {
        groups.removeValue(forKey: key)
        emit()
    }

    func decrementRefCount(key: StreamKey) {
        if let count = groups[key] {
            if count == 1 {
                removeStreamGroup(key: key)
            } else {
                groups[key] = count - 1
            }
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
        return try await db.group.syncCoordinator.streams.subscribe(db: db, stream: self, ttl: ttl, priority: priority)
    }
    
    func unsubscribeAll() async throws {
        let tracker = db.group.syncCoordinator.streams
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
        db.group.syncCoordinator.streams.decrementRefCount(key: key)
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
