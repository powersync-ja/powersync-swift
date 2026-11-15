import Foundation
import PowerSync

/// PowerSync DevTools for a running app: a small server on the device's loopback interface that
/// serves the DevTools page and MCP tools for coding agents.
///
/// ```swift
/// let devTools = try await PowerSyncDevTools.start(database: db)
/// ```
///
/// The server exists in debug builds only. In a release build of the app this library compiles
/// without it, and `start` returns `nil`.
///
/// The page and MCP endpoint are reachable from the same machine only: the Mac for a simulator or a
/// macOS app. The printed URL carries a random token that every request must present.
public final class PowerSyncDevTools: Sendable {
    static let version = "0.0.1-prototype"

    /// The DevTools page, including the token.
    public let url: URL
    /// The MCP endpoint. Send the token as `Authorization: Bearer <token>`.
    public let mcpURL: URL
    public let token: String

    #if POWERSYNC_DEVTOOLS && canImport(Network) && !os(watchOS)
    private let server: HTTPServer
    private let agent: DevToolsAgent

    private init(url: URL, mcpURL: URL, token: String, server: HTTPServer, agent: DevToolsAgent) {
        self.url = url
        self.mcpURL = mcpURL
        self.token = token
        self.server = server
        self.agent = agent
    }
    #else
    // Never called: `start` returns nil when the server is compiled out.
    private init() {
        url = URL(fileURLWithPath: "/")
        mcpURL = url
        token = ""
    }
    #endif

    /// Starts DevTools for `database` and prints the page URL. `port` 0 picks a free port.
    /// Returns `nil` in release builds, and on platforms without a network listener (watchOS).
    public static func start(database: any PowerSyncDatabaseProtocol, port: UInt16 = 0) async throws -> PowerSyncDevTools? {
        #if POWERSYNC_DEVTOOLS && canImport(Network) && !os(watchOS)
        let token = randomToken()
        let agent = DevToolsAgent(database: database)
        let router = Router(agent: agent, token: token)
        let server = try HTTPServer(port: port) { request, responder in
            await router.handle(request, responder)
        }
        let boundPort = try await server.start()
        await agent.start()

        let base = "http://127.0.0.1:\(boundPort)"
        let devTools = PowerSyncDevTools(
            url: URL(string: "\(base)/#token=\(token)")!,
            mcpURL: URL(string: "\(base)/__mcp")!,
            token: token,
            server: server,
            agent: agent
        )
        print("PowerSync DevTools: \(devTools.url.absoluteString)")
        print("PowerSync DevTools MCP: \(devTools.mcpURL.absoluteString) (header Authorization: Bearer \(token))")
        return devTools
        #else
        return nil
        #endif
    }

    public func stop() async {
        #if POWERSYNC_DEVTOOLS && canImport(Network) && !os(watchOS)
        server.stop()
        await agent.stop()
        #endif
    }
}

#if POWERSYNC_DEVTOOLS && canImport(Network) && !os(watchOS)
private func randomToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
}

/// Maps requests to the page files, the DevTools protocol and MCP.
private struct Router: Sendable {
    let agent: DevToolsAgent
    let token: String

    func handle(_ request: HTTPRequest, _ responder: HTTPResponder) async {
        // Browsers send `Origin` on cross-origin requests; only loopback pages may call in.
        if let origin = request.header("origin"), !Self.isLoopback(origin) {
            responder.sendJSON(status: 403, .object(["error": .object(["message": "Forbidden origin"])]))
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/__powersync/host.json"):
            responder.sendJSON(.object(["protocol": 1, "sdk": "swift"]))
        case ("POST", "/__powersync/rpc"):
            guard authorized(request) else { return unauthorized(responder) }
            await rpc(request, responder)
        case ("GET", "/__powersync/events"):
            guard authorized(request) else { return unauthorized(responder) }
            let ids = SubscriptionBox()
            let stream = responder.startEventStream { [agent] in
                Task { if let id = ids.id { await agent.unsubscribe(id) } }
            }
            ids.id = await agent.subscribe(stream)
        case ("POST", "/__mcp"):
            guard authorized(request) else { return unauthorized(responder) }
            guard let message = JsonValue.parse(request.body) else {
                return responder.sendJSON(status: 400, .object(["error": "Invalid JSON"]))
            }
            if let reply = await MCPTools.handle(message, agent: agent) {
                responder.sendJSON(reply)
            } else {
                responder.send(status: 202, contentType: "application/json", body: Data())
            }
        case ("GET", _):
            serveFile(request.path, responder)
        default:
            responder.sendJSON(status: 405, .object(["error": "Method not allowed"]))
        }
    }

    private func rpc(_ request: HTTPRequest, _ responder: HTTPResponder) async {
        guard let message = JsonValue.parse(request.body), let method = message["method"]?.stringValue else {
            return responder.sendJSON(status: 400, .object(["error": .object(["message": "Invalid request"])]))
        }
        let params = message["params"]
        do {
            let result: JsonValue
            switch method {
            case "runQuery":
                guard let sql = params?["sql"]?.stringValue else { throw DevToolsError.badRequest("runQuery needs sql") }
                result = try await agent.runQuery(sql: sql, params: params?["params"]?.arrayValue ?? [])
            case "getSchema":
                result = await agent.getSchema()
            case "getInfo":
                // The page decodes the token to show the user id, as on the web.
                result = await agent.getInfo(includeToken: true)
            case "action":
                guard let action = params?["action"]?.stringValue else { throw DevToolsError.badRequest("action needs action") }
                try await agent.action(name: action, args: params?["args"])
                result = .null
            default:
                throw DevToolsError.badRequest("Unknown method: \(method)")
            }
            responder.sendJSON(.object(["result": result]))
        } catch {
            responder.sendJSON(.object(["error": .object(["message": .string(String(describing: error))])]))
        }
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        let presented = request.header("authorization").map { $0.replacingOccurrences(of: "Bearer ", with: "") }
            ?? request.query["token"]
        guard let presented, presented.utf8.count == token.utf8.count else { return false }
        // Compares every byte, so the time taken does not reveal the token.
        return zip(presented.utf8, token.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func unauthorized(_ responder: HTTPResponder) {
        responder.sendJSON(status: 401, .object(["error": .object(["message": "Missing or wrong DevTools token"])]))
    }

    private func serveFile(_ path: String, _ responder: HTTPResponder) {
        let relative = path == "/" ? "index.html" : String(path.dropFirst())
        guard !relative.contains(".."),
              let root = Bundle.module.url(forResource: "ui", withExtension: nil),
              let data = try? Data(contentsOf: root.appendingPathComponent(relative))
        else {
            return responder.send(status: 404, contentType: "text/plain", body: Data("Not found".utf8))
        }
        responder.send(status: 200, contentType: Self.contentType(relative), body: data)
    }

    private static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript"
        case "css": "text/css"
        case "svg": "image/svg+xml"
        case "json": "application/json"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }

    private static func isLoopback(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

/// Holds the event subscription id until the stream closes.
private final class SubscriptionBox: @unchecked Sendable {
    var id: UUID?
}
#endif
