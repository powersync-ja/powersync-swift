struct CoreDownloadSyncStatus: Decodable, Sendable {
    let connected: Bool
    let connecting: Bool
    let priorityStatus: [PriorityStatusEntry]
    let downloading: CoreSyncDownloadProgress?
    let streams: [SyncStreamStatus]
    
    enum CodingKeys: String, CodingKey {
        case connected
        case connecting
        case priorityStatus = "priority_status"
        case downloading
        case streams
    }
    
    init() {
        self.connected = false
        self.connecting = false
        self.priorityStatus = []
        self.downloading = nil
        self.streams = []
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.connected = try container.decode(Bool.self, forKey: .connected)
        self.connecting = try container.decode(Bool.self, forKey: .connecting)
        self.priorityStatus = try container.decode([PriorityStatusEntry].self, forKey: .priorityStatus)
        self.downloading = try container.decodeIfPresent(CoreSyncDownloadProgress.self, forKey: .downloading)
        
        var streamsContainer = try container.nestedUnkeyedContainer(forKey: .streams)
        var streams: [SyncStreamStatus] = []
        while !streamsContainer.isAtEnd {
            streams.append(try streamsContainer.decode(DecodableSyncStreamStatus.self).inner)
        }
        self.streams = streams
    }
}

struct BucketProgress: Decodable {
    let priority: BucketPriority
    let atLast:  Int64
    let sinceLast: Int64
    let targetCount: Int64
    
    enum CodingKeys: String, CodingKey {
        case priority
        case atLast = "at_last"
        case sinceLast = "since_last"
        case targetCount = "target_count"
    }
}

struct CoreSyncDownloadProgress: Decodable {
    let buckets: [String: BucketProgress]
}

struct ProgressCounters: Decodable, ProgressWithOperations {
    let total: Int32
    let downloaded: Int32
    
    var totalOperations: Int32 {
        total
    }
    
    var downloadedOperations: Int32 {
        downloaded
    }
}

private struct DecodableSyncStreamStatus: Decodable {
    let inner: SyncStreamStatus
    
    init(from decoder: any Decoder) throws {
        self.inner = try SyncStreamStatus.init(from: decoder)
    }
}
