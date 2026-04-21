/// Arguments to the `powersync_control()` SQL function driving the sync process.
enum PowerSyncControlArguments {
    case start(_ start: StartSyncIteration)
    case stop
    case textLine(line: String)
    case binaryLine(line: ContiguousArray<UInt8>)
    case completedUpload
    case didRefreshToken
    case connectionEstablished
    case responseStreamEnd
    case updateSubscriptions(streams: [StreamKey])
    
    func execute(_ context: ConnectionContext) throws -> String {
        let op: String
        let param: Sendable?
        
        switch (self) {
        case .start(let start):
            op = "start"
            param = String(data: try StreamingSyncClient.jsonEncoder.encode(start), encoding: .utf8)
        case .stop:
            op = "stop"
            param = nil
        case .textLine(line: let line):
            op = "line_text"
            param = line
        case .binaryLine(line: let line):
            op = "line_binary"
            param = line
        case .completedUpload:
            op = "completed_upload"
            param = nil
        case .didRefreshToken:
            op = "refreshed_token"
            param = nil
        case .connectionEstablished:
            op = "connection"
            param = "established"
        case .responseStreamEnd:
            op = "connection"
            param = "end"
        case .updateSubscriptions(streams: let streams):
            op = "update_subscriptions"
            param = String(data: try StreamingSyncClient.jsonEncoder.encode(streams), encoding: .utf8)
        }
        
        return try context.get(sql: "SELECT powersync_control(?, ?)", parameters: [op, param]) { cursor in
            try cursor.getString(index: 0)
        }
    }
    
    func isSyncLine() -> Bool {
        switch self {
        case .binaryLine(line: _):
            return true
        case .textLine(line: _):
            return true
        default:
            return false
        }
    }
}

struct StartSyncIteration: Encodable {
    let parameters: JsonParam
    let schema: Schema
    let includeDefaults: Bool
    let activeStreams: [StreamKey]
    let appMetadata: [String: String]
    
    enum CodingKeys: String, CodingKey {
        case parameters
        case schema
        case includeDefaults = "include_defaults"
        case activeStreams = "active_streams"
        case appMetadata = "app_metadata"
    }
}

struct StreamKey: Codable, Equatable, Hashable {
    let name: String
    let params: JsonParam?
}
