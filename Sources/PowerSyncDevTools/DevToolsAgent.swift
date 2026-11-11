#if POWERSYNC_DEVTOOLS && canImport(Network) && !os(watchOS)
import Foundation
@_spi(PowerSyncDevTools) import PowerSync

/// Serves one database to the DevTools page and to agents: the Swift side of the diagnostics
/// protocol (`SdkIntegration` and the event shapes in `@powersync/diagnostics-core`).
actor DevToolsAgent {
    let database: any PowerSyncDatabaseProtocol

    private var subscribers: [UUID: EventStream] = [:]
    /// The latest snapshot of each replayed event type, sent to every new subscriber.
    private var snapshots: [String: JsonValue] = [:]
    /// Per-bucket total operation counts from the core diagnostics events.
    private var bucketTargets: [String: Int] = [:]
    private var streamSubscriptions: [String: any SyncStreamSubscription] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var cleanups: [@Sendable () -> Void] = []

    init(database: any PowerSyncDatabaseProtocol) {
        self.database = database
    }

    // MARK: - Lifecycle

    func start() {
        let statusTask = Task { [weak self, database] in
            for await status in database.currentStatus.asFlow() {
                await self?.statusChanged(status)
            }
        }
        // `watch` finds the tables a query reads, so this fires on every change to the three.
        let tablesTask = Task { [weak self, database] in
            let sql = "SELECT (SELECT 1 FROM ps_buckets LIMIT 1), (SELECT 1 FROM ps_oplog LIMIT 1), (SELECT 1 FROM ps_crud LIMIT 1)"
            guard let changes = try? database.watch(sql: sql, parameters: [], mapper: { _ in 0 }) else { return }
            do {
                for try await _ in changes {
                    await self?.pushBuckets()
                    await self?.pushUploadQueue()
                }
            } catch {}
        }
        tasks = [statusTask, tablesTask]

        let removeListener = database.devToolsAddDiagnosticsListener { [weak self] event in
            Task { await self?.coreEvent(event) }
        }
        cleanups.append(removeListener)

        if let logger = database.logger as? DefaultLogger {
            let writer = LogCollector { [weak self] record in
                Task { await self?.emit(type: "newLogs", payload: .array([record])) }
            }
            logger.addWriter(writer)
            cleanups.append { logger.removeWriter(writer) }
        }
    }

    func stop() async {
        for task in tasks { task.cancel() }
        for cleanup in cleanups { cleanup() }
        for subscription in streamSubscriptions.values { try? await subscription.unsubscribe() }
        for subscriber in subscribers.values { subscriber.close() }
        tasks = []
        cleanups = []
        streamSubscriptions = [:]
        subscribers = [:]
    }

    // MARK: - Events

    func subscribe(_ stream: EventStream) -> UUID {
        let id = UUID()
        subscribers[id] = stream
        for type in ["status", "streams", "buckets", "uploadQueue"] {
            if let payload = snapshots[type] {
                stream.send(.object(["type": .string(type), "payload": payload]))
            }
        }
        return id
    }

    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    func latest(_ type: String) -> JsonValue {
        snapshots[type] ?? .null
    }

    private func emit(type: String, payload: JsonValue) {
        if type != "newLogs" && type != "core" {
            snapshots[type] = payload
        }
        let event = JsonValue.object(["type": .string(type), "payload": payload])
        for subscriber in subscribers.values { subscriber.send(event) }
    }

    private func statusChanged(_ status: any SyncStatusData) async {
        emit(type: "status", payload: Self.syncState(status))
        emit(type: "streams", payload: .array((status.syncStreams ?? []).map(Self.streamState)))
        await pushUploadQueue()
        await pushBuckets()
    }

    private func coreEvent(_ event: JsonValue) async {
        emit(type: "core", payload: event)
        if let changes = event["BucketStateChange"]?["changes"]?.arrayValue {
            for change in changes {
                if let name = change["name"]?.stringValue, let target = change["progress"]?["target_count"]?.intValue {
                    bucketTargets[name] = target
                }
            }
            await pushBuckets()
        }
    }

    private func pushUploadQueue() async {
        let row = try? await database.get(
            sql: "SELECT count(*), sum(length(data)) FROM ps_crud",
            parameters: [],
            mapper: { cursor in (cursor.getInt64Optional(index: 0) ?? 0, cursor.getInt64Optional(index: 1)) }
        )
        guard let row else { return }
        emit(type: "uploadQueue", payload: .object([
            "count": .int(Int(row.0)),
            "size": row.1.map { .int(Int($0)) } ?? .null
        ]))
    }

    private func pushBuckets() async {
        let downloading = database.currentStatus.downloading
        let rows = try? await database.getAll(
            sql: "SELECT name, count_at_last + count_since_last, downloaded_size, last_op FROM ps_buckets ORDER BY name",
            parameters: [],
            mapper: { cursor in
                (try cursor.getString(index: 0), cursor.getInt64Optional(index: 1) ?? 0,
                 cursor.getInt64Optional(index: 2), cursor.getStringOptional(index: 3))
            }
        )
        guard let rows else { return }
        emit(type: "buckets", payload: .array(rows.map { row in
            .object([
                "name": .string(row.0),
                "downloadedOperations": .int(Int(row.1)),
                "totalOperations": .optional(bucketTargets[row.0]),
                "downloadedSize": row.2.map { .int(Int($0)) } ?? .null,
                "lastOp": .optional(row.3),
                "downloading": .bool(downloading)
            ])
        }))
    }

    // MARK: - SdkIntegration

    /// Runs any SQL. Plain reads use a read connection; everything else runs on the write connection.
    func runQuery(sql: String, params: [JsonValue]) async throws -> JsonValue {
        let parameters = params.map(\.sqlParameter)
        let mapper: @Sendable (SqlCursor) throws -> ([String], [JsonValue]) = { cursor in
            let indices = 0..<cursor.columnCount
            return (indices.map { cursor.columnName(index: $0) }, indices.map { cursor.getValue(index: $0)?.json ?? .null })
        }
        let isRead = sql.range(of: #"^\s*(select|explain)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let rows = isRead
            ? try await database.getAll(sql: sql, parameters: parameters, mapper: mapper)
            : try await database.writeLock { context in try context.getAll(sql: sql, parameters: parameters, mapper: mapper) }
        return .object([
            "columns": .array((rows.first?.0 ?? []).map { .string($0) }),
            "rows": .array(rows.map { .array($0.1) })
        ])
    }

    func getSchema() async -> JsonValue {
        guard let schema = await database.devToolsSchema() else { return .null }
        return .from(schema)
    }

    func getInfo(includeToken: Bool) async -> JsonValue {
        let credentials = await database.devToolsCredentials()
        let clientId = try? await database.get(sql: "SELECT powersync_client_id()", parameters: [], mapper: { try $0.getString(index: 0) })
        let version = try? await database.getPowerSyncVersion()
        let params = database.devToolsConnectOptions?.params
        var info: [String: JsonValue] = [
            "endpoint": .optional(credentials?.endpoint),
            "token": includeToken ? .optional(credentials?.token) : .null,
            "clientId": .optional(clientId),
            "connectionMethod": .string("http"),
            "params": params.map { .object($0) } ?? .null,
            "connected": .bool(database.currentStatus.connected),
            "sqliteCoreVersion": .optional(version),
            "sdk": .string("powersync-swift"),
            "databasePath": .optional(database.devToolsDatabaseFilename)
        ]
        if !includeToken {
            info["userId"] = .optional(credentials.flatMap { Self.jwtSubject($0.token) })
        }
        return .object(info)
    }

    func action(name: String, args: JsonValue?) async throws {
        switch name {
        case "disconnect":
            try await database.disconnect()
        case "reconnect":
            try await database.disconnect()
            try await database.devToolsReconnect()
        case "clearData":
            try await database.disconnectAndClear()
            try await database.devToolsReconnect()
        case "requestCheckpoint":
            let checkpoint = try await database.requestCheckpoint()
            try await checkpoint.waitForSync(timeout: 120)
        case "subscribeStream":
            guard let streamName = args?["name"]?.stringValue else { throw DevToolsError.badRequest("subscribeStream needs args.name") }
            let params = args?["params"]?.objectValue
            let priority = args?["priority"]?.intValue.map { BucketPriority(Int32($0)) }
            let subscription = try await database.syncStream(name: streamName, params: params)
                .subscribe(ttl: args?["ttl"]?.doubleValue ?? 0, priority: priority)
            streamSubscriptions[Self.streamKey(streamName, params)] = subscription
        case "unsubscribeStream":
            guard let streamName = args?["name"]?.stringValue else { throw DevToolsError.badRequest("unsubscribeStream needs args.name") }
            let key = Self.streamKey(streamName, args?["params"]?.objectValue)
            try await streamSubscriptions.removeValue(forKey: key)?.unsubscribe()
        default:
            throw DevToolsError.badRequest("Unknown action: \(name)")
        }
    }

    // MARK: - Mapping

    private static func syncState(_ status: any SyncStatusData) -> JsonValue {
        .object([
            "connected": .bool(status.connected),
            "connecting": .bool(status.connecting),
            "downloading": .bool(status.downloading),
            "uploading": .bool(status.uploading),
            "hasSynced": .optional(status.hasSynced),
            "lastSyncedAt": epochMillis(status.lastSyncedAt),
            "downloadProgress": status.downloadProgress.map(progress) ?? .null,
            "priorities": .array(status.priorityStatusEntries.map { entry in
                .object([
                    "priority": .int(Int(entry.priority.priorityCode)),
                    "lastSyncedAt": epochMillis(entry.lastSyncedAt),
                    "hasSynced": .optional(entry.hasSynced)
                ])
            }),
            "downloadError": status.downloadError.map { .string(String(describing: $0)) } ?? .null,
            "uploadError": status.uploadError.map { .string(String(describing: $0)) } ?? .null
        ])
    }

    private static func streamState(_ stream: SyncStreamStatus) -> JsonValue {
        let subscription = stream.subscription
        return .object([
            "name": .string(subscription.name),
            // The Swift SDK does not report a stream's priority yet.
            "priority": .null,
            "active": .bool(subscription.active),
            "autoSubscribed": .bool(subscription.isDefault),
            "explicitlySubscribed": .bool(subscription.hasExplicitSubscription),
            "progress": stream.progress.map(progress) ?? .null,
            "params": subscription.parameters.map { .object($0) } ?? .null,
            "expiresAt": epochMillis(subscription.expiresAt),
            "hasSynced": .bool(subscription.hasSynced),
            "lastSyncedAt": epochMillis(subscription.lastSyncedAt)
        ])
    }

    private static func progress(_ progress: any ProgressWithOperations) -> JsonValue {
        .object([
            "downloadedOperations": .int(Int(progress.downloadedOperations)),
            "totalOperations": .int(Int(progress.totalOperations))
        ])
    }

    private static func streamKey(_ name: String, _ params: [String: JsonValue]?) -> String {
        name + "|" + String(decoding: JsonValue.optionalObject(params).jsonData(), as: UTF8.self)
    }

    /// The `sub` claim of a JWT, without verifying it.
    static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return JsonValue.parse(data)?["sub"]?.stringValue
    }
}

private extension JsonValue {
    static func optionalObject(_ object: [String: JsonValue]?) -> JsonValue {
        object.map { .object($0) } ?? .null
    }
}

enum DevToolsError: Error, CustomStringConvertible {
    case badRequest(String)

    var description: String {
        switch self {
        case .badRequest(let message): message
        }
    }
}

/// Collects SDK log lines next to the app's own log writers.
final class LogCollector: LogWriterProtocol, @unchecked Sendable {
    private let onRecord: @Sendable (JsonValue) -> Void

    init(onRecord: @escaping @Sendable (JsonValue) -> Void) {
        self.onRecord = onRecord
    }

    func log(severity: LogSeverity, message: String, tag: String?) {
        let level = switch severity {
        case .debug: "debug"
        case .info: "info"
        case .warning: "warn"
        case .error, .fault: "error"
        }
        let text = tag.map { $0.isEmpty ? message : "[\($0)] \(message)" } ?? message
        onRecord(.object([
            "timestamp": epochMillis(Date()),
            "level": .string(level),
            "message": .string(text)
        ]))
    }
}
#endif
