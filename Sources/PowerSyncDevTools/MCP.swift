#if POWERSYNC_DEVTOOLS && canImport(Network) && !os(watchOS)
import Foundation
import PowerSync

/// The MCP tools: the same names and descriptions as the JS hosts (`tools.ts` in
/// `@powersync/diagnostics`), with named arguments instead of devframe's positional ones.
enum MCPTools {
    static let actionNames = ["reconnect", "disconnect", "clearData", "requestCheckpoint", "subscribeStream", "unsubscribeStream"]

    static let list: JsonValue = .array([
        tool(
            "powersync_query",
            "Run SQL against the PowerSync SQLite database. App tables are views; the sync client state is in the ps_* tables (ps_buckets, ps_oplog, ps_crud, ps_stream_subscriptions). Returns columns and rows.",
            properties: [
                "sql": ["type": "string", "description": "SQL to run against the local SQLite database."],
                "params": ["type": "array", "description": "Positional parameters for `?` placeholders."]
            ],
            required: ["sql"]
        ),
        tool("powersync_schema", "The client schema as the PowerSync SQLite core receives it: tables, columns, indexes.", readOnly: true),
        tool(
            "powersync_info",
            "Connection info of the PowerSync client: endpoint, user id, client id, connection method, core version.",
            readOnly: true
        ),
        tool(
            "powersync_status",
            "The latest sync status the PowerSync client reported: connected, downloading, progress, last sync, errors. Null until it has reported.",
            readOnly: true
        ),
        tool(
            "powersync_upload-queue",
            "Pending local changes waiting to upload, as last reported: count and size. Null until reported.",
            readOnly: true
        ),
        tool(
            "powersync_action",
            "Run a control action on the PowerSync client: reconnect, disconnect, clearData (wipes local data and re-syncs), requestCheckpoint, subscribeStream, unsubscribeStream.",
            properties: [
                "action": ["type": "string", "enum": .array(actionNames.map { .string($0) })],
                "args": [
                    "type": "object",
                    "description": "Stream name and options, for subscribeStream and unsubscribeStream only: { name, params?, ttl?, priority? }."
                ]
            ],
            required: ["action"],
            destructive: true
        )
    ])

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: JsonValue] = [:],
        required: [String] = [],
        readOnly: Bool = false,
        destructive: Bool = false
    ) -> JsonValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) })
            ]),
            "annotations": .object(["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive)])
        ])
    }

    /// Answers one JSON-RPC message. Returns nil for notifications, which get no reply.
    static func handle(_ message: JsonValue, agent: DevToolsAgent) async -> JsonValue? {
        let id = message["id"]
        let method = message["method"]?.stringValue ?? ""
        guard let id else { return nil }

        func result(_ value: JsonValue) -> JsonValue {
            .object(["jsonrpc": "2.0", "id": id, "result": value])
        }

        switch method {
        case "initialize":
            let version = message["params"]?["protocolVersion"]?.stringValue ?? "2025-06-18"
            return result(.object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": "powersync-devtools", "version": .string(PowerSyncDevTools.version)])
            ]))
        case "ping":
            return result(.object([:]))
        case "tools/list":
            return result(.object(["tools": list]))
        case "tools/call":
            let name = message["params"]?["name"]?.stringValue ?? ""
            let arguments = message["params"]?["arguments"]
            do {
                let value = try await call(name, arguments, agent: agent)
                return result(.object(["content": .array([.object(["type": "text", "text": .string(String(decoding: value.jsonData(), as: UTF8.self))])])]))
            } catch {
                return result(.object([
                    "content": .array([.object(["type": "text", "text": .string(String(describing: error))])]),
                    "isError": true
                ]))
            }
        default:
            return .object([
                "jsonrpc": "2.0", "id": id,
                "error": .object(["code": -32601, "message": .string("Method not found: \(method)")])
            ])
        }
    }

    private static func call(_ name: String, _ arguments: JsonValue?, agent: DevToolsAgent) async throws -> JsonValue {
        switch name {
        case "powersync_query":
            guard let sql = arguments?["sql"]?.stringValue else { throw DevToolsError.badRequest("query needs sql") }
            return try await agent.runQuery(sql: sql, params: arguments?["params"]?.arrayValue ?? [])
        case "powersync_schema":
            return await agent.getSchema()
        case "powersync_info":
            // Agents get the user id, not the session token.
            return await agent.getInfo(includeToken: false)
        case "powersync_status":
            return await agent.latest("status")
        case "powersync_upload-queue":
            return await agent.latest("uploadQueue")
        case "powersync_action":
            guard let action = arguments?["action"]?.stringValue else { throw DevToolsError.badRequest("action needs action") }
            try await agent.action(name: action, args: arguments?["args"])
            return .object(["ok": true])
        default:
            throw DevToolsError.badRequest("Unknown tool: \(name)")
        }
    }
}
#endif
