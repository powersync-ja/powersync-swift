import Foundation
import PowerSync
import PowerSyncDevTools
import Testing

@Suite("DevTools server")
struct DevToolsServerTests {
    private func openDatabase() -> PowerSyncDatabaseProtocol {
        PowerSyncDatabase(
            schema: Schema(tables: [Table(name: "todos", columns: [.text("description"), .integer("done")])]),
            dbFilename: ":memory:"
        )
    }

    private func request(
        _ devTools: PowerSyncDevTools,
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        token: String? = nil
    ) async throws -> (Int, Data) {
        let base = devTools.mcpURL.deletingLastPathComponent()
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func servesThePageAndHostInfo() async throws {
        let devTools = try #require(try await PowerSyncDevTools.start(database: openDatabase()))
        defer { Task { await devTools.stop() } }

        let (pageStatus, page) = try await request(devTools, "/")
        #expect(pageStatus == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("<div id=\"app\">"))

        let (hostStatus, host) = try await request(devTools, "__powersync/host.json")
        #expect(hostStatus == 200)
        #expect(try json(host)["sdk"] as? String == "swift")
    }

    @Test func rejectsRequestsWithoutTheToken() async throws {
        let devTools = try #require(try await PowerSyncDevTools.start(database: openDatabase()))
        defer { Task { await devTools.stop() } }

        let (status, _) = try await request(devTools, "__powersync/rpc", method: "POST", body: ["method": "getSchema"])
        #expect(status == 401)
        let (mcpStatus, _) = try await request(devTools, "__mcp", method: "POST", body: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], token: "wrong")
        #expect(mcpStatus == 401)
    }

    @Test func runsReadsAndWritesOverRpc() async throws {
        let devTools = try #require(try await PowerSyncDevTools.start(database: openDatabase()))
        defer { Task { await devTools.stop() } }

        func runQuery(_ sql: String) async throws -> [String: Any] {
            let (_, data) = try await request(
                devTools, "__powersync/rpc", method: "POST",
                body: ["method": "runQuery", "params": ["sql": sql]], token: devTools.token
            )
            return try json(data)
        }

        _ = try await runQuery("INSERT INTO todos (id, description, done) VALUES (uuid(), 'from devtools', 0)")
        let response = try await runQuery("SELECT description, done, x'0102' AS blob, NULL AS empty FROM todos")
        let result = response["result"] as! [String: Any]
        #expect(result["columns"] as? [String] == ["description", "done", "blob", "empty"])
        let row = (result["rows"] as! [[Any]])[0]
        #expect(row[0] as? String == "from devtools")
        #expect(row[1] as? Int == 0)
        #expect((row[2] as? [String: String])?["binary"] == "AQI=")
        #expect(row[3] is NSNull)

        let crud = try await runQuery("SELECT count(*) AS n FROM ps_crud")["result"] as! [String: Any]
        #expect((crud["rows"] as! [[Any]])[0][0] as? Int == 1)

        let (_, schemaData) = try await request(
            devTools, "__powersync/rpc", method: "POST", body: ["method": "getSchema"], token: devTools.token
        )
        let tables = (try json(schemaData)["result"] as! [String: Any])["tables"] as! [[String: Any]]
        #expect(tables.first?["name"] as? String == "todos")
    }

    @Test func servesTheSixToolsOverMcp() async throws {
        let devTools = try #require(try await PowerSyncDevTools.start(database: openDatabase()))
        defer { Task { await devTools.stop() } }

        let (_, initData) = try await request(
            devTools, "__mcp", method: "POST",
            body: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
            token: devTools.token
        )
        #expect((try json(initData)["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")

        let (_, listData) = try await request(
            devTools, "__mcp", method: "POST", body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: devTools.token
        )
        let tools = ((try json(listData)["result"] as! [String: Any])["tools"] as! [[String: Any]]).map { $0["name"] as! String }
        #expect(tools == ["powersync_query", "powersync_schema", "powersync_info", "powersync_status", "powersync_upload-queue", "powersync_action"])

        let (_, callData) = try await request(
            devTools, "__mcp", method: "POST",
            body: ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "powersync_query", "arguments": ["sql": "SELECT 1 + 1 AS two"]]],
            token: devTools.token
        )
        let content = ((try json(callData)["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String
        #expect(content.contains("\"two\""))
        #expect(content.contains("[[2]]"))
    }
}
