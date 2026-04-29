// Helpers to encode sync lines sent by the PowerSync service, used to test sync with a mocked HTTP client.
import AsyncAlgorithms
@testable import PowerSync

enum SyncLine: Encodable {
    case fullCheckpoint(Checkpoint)
    case checkpointComplete(lastOpId: String)
    case checkpointPartiallyComplete(lastOpId: String, priority: BucketPriority)
    case syncDataBucket(SyncDataBucket)
    case keepAlive(tokenExpiresIn: Int)
    
    enum CodingKeys: String, CodingKey {
        case fullCheckpoint = "checkpoint"
        case checkpointComplete = "checkpoint_complete"
        case checkpointPartiallyComplete = "partial_checkpoint_complete"
        case syncDataBucket = "data"
        case keepAlive = "token_expires_in"
    }
    
    enum CheckpointCompleteCodingKeys: String, CodingKey {
        case lastOpId = "last_op_id"
    }
    
    enum CheckpointPartiallyCompleteCodingKeys: String, CodingKey {
        case lastOpId = "last_op_id"
        case priority
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullCheckpoint(let checkpoint):
            var nestedContainer = container.nestedContainer(keyedBy: Checkpoint.CodingKeys.self, forKey: .fullCheckpoint)
            try checkpoint.encodeToContainer(&nestedContainer)
        case .checkpointComplete(let lastOpId):
            var nestedContainer = container.nestedContainer(keyedBy: SyncLine.CheckpointCompleteCodingKeys.self, forKey: .checkpointComplete)
            try nestedContainer.encode(lastOpId, forKey: SyncLine.CheckpointCompleteCodingKeys.lastOpId)
        case .checkpointPartiallyComplete(let lastOpId, let priority):
            var nestedContainer = container.nestedContainer(keyedBy: SyncLine.CheckpointPartiallyCompleteCodingKeys.self, forKey: .checkpointPartiallyComplete)
            try nestedContainer.encode(lastOpId, forKey: SyncLine.CheckpointPartiallyCompleteCodingKeys.lastOpId)
            try nestedContainer.encode(priority, forKey: SyncLine.CheckpointPartiallyCompleteCodingKeys.priority)
        case .syncDataBucket(let bucket):
            var nestedContainer = container.nestedContainer(keyedBy: SyncDataBucket.CodingKeys.self, forKey: .syncDataBucket)
            try bucket.encodeToContainer(&nestedContainer)
        case .keepAlive(let tokenExpiresIn):
            try container.encode(tokenExpiresIn, forKey: .keepAlive)
        }
    }
}

struct SyncDataBucket {
    var bucket: String
    var data: [OplogEntry]
    var hasMore: Bool = false
    var after: String? = nil
    var nextAfter: String? = nil
    
    enum CodingKeys: String, CodingKey {
        case bucket
        case data
        case hasMore = "has_more"
        case after
        case nextAfter = "next_after"
    }
    
    func encodeToContainer(_ container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(self.bucket, forKey: .bucket)
        try container.encode(self.data, forKey: .data)
        try container.encode(self.hasMore, forKey: .hasMore)
        try container.encode(self.after, forKey: .after)
        try container.encode(self.nextAfter, forKey: .nextAfter)
    }
}

struct Checkpoint {
    var last_op_id: String
    var buckets: [BucketChecksum]
    var writeCheckpoint: String? = nil
    var streams: [StreamDescription] = []
    
    enum CodingKeys: String, CodingKey {
        case last_op_id
        case buckets
        case writeCheckpoint = "write_checkpoint"
        case streams
    }
    
    func encodeToContainer(_ container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(self.last_op_id, forKey: .last_op_id)
        try container.encode(self.buckets, forKey: .buckets)
        try container.encode(self.writeCheckpoint, forKey: .writeCheckpoint)
        try container.encode(self.streams, forKey: .streams)
    }
}

struct StreamDescription: Encodable {
    var name: String
    var is_default: Bool
    var errors: [Never] = []
}

struct OplogEntry: Encodable {
    var checksum: Int32
    var op_id: String
    var object_id: String
    var object_type: String
    var op: OpType? = nil
    var subkey: String? = nil
    var data: String? = nil
}

enum OpType: String, Codable {
    case clear = "CLEAR"
    case move = "MOVE"
    case put = "PUT"
    case remove = "REMOVE"
}

struct BucketChecksum: Encodable {
    var bucket: String
    var priority: BucketPriority = .defaultPriority
    var checksum: Int32
    var count: Int? = nil
    var lastOpId: String? = nil
    var subscriptions: [BucketSubscriptionReason]? = nil
    
    enum CodingKeys: String, CodingKey {
        case bucket
        case priority
        case checksum
        case count
        case last_op_id = "last_op_id"
        case subscriptions
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.bucket, forKey: .bucket)
        try container.encode(self.priority, forKey: .priority)
        try container.encode(self.checksum, forKey: .checksum)
        try container.encode(self.count, forKey: .count)
        try container.encode(self.lastOpId, forKey: .last_op_id)
        try container.encodeIfPresent(self.subscriptions, forKey: .subscriptions)
    }
}

enum BucketSubscriptionReason: Encodable {
    case defaultStream(Int)
    case explicitSubscription(Int)
    
    enum CodingKeys: String, CodingKey {
        case defaultStream = "default"
        case explicitSubscription = "sub"
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .defaultStream(let idx):
            try container.encode(idx, forKey: .defaultStream)
        case .explicitSubscription(let idx):
            try container.encode(idx, forKey: .explicitSubscription)
        }
    }
}

extension AsyncThrowingChannel<PowerSync.SyncLine, any Error> {
    func pushLine(_ line: SyncLine) async throws {
        let encoded = try StreamingSyncClient.jsonEncoder.encode(line)
        await send(.text(contents: String(data: encoded, encoding: .utf8)!))
    }
}
