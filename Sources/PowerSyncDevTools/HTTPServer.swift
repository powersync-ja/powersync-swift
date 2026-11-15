#if POWERSYNC_DEVTOOLS && canImport(Network) && !os(watchOS)
import Foundation
import Network
import PowerSync

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Replies to one request: either once with ``send(status:contentType:body:)``, or as a stream of
/// server-sent events with ``startEventStream()``.
final class HTTPResponder: @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(status: Int, contentType: String, body: Data, extraHeaders: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += "Cache-Control: no-store\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    func sendJSON(status: Int = 200, _ value: JsonValue) {
        send(status: status, contentType: "application/json", body: value.jsonData())
    }

    /// Opens a server-sent event stream. `onClose` runs once when the client goes away.
    func startEventStream(onClose: @escaping @Sendable () -> Void) -> EventStream {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let stream = EventStream(connection: connection)
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                onClose()
            default:
                break
            }
        }
        // Reading detects the client closing the stream.
        stream.watchForClose(onClose: onClose)
        return stream
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }
}

final class EventStream: @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ value: JsonValue) {
        let line = "data: " + String(decoding: value.jsonData(), as: UTF8.self) + "\n\n"
        connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }

    func watchForClose(onClose: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                onClose()
                self?.connection.cancel()
            } else {
                self?.watchForClose(onClose: onClose)
            }
        }
    }
}

/// A minimal HTTP/1.1 server on the loopback interface: one request per connection.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, HTTPResponder) async -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "PowerSyncDevTools.HTTPServer")
    private let handler: Handler

    init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        // Loopback only: the simulator shares the Mac's loopback, other machines cannot connect.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    /// Starts listening and returns the port it got.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let responder = HTTPResponder(connection: connection)
                let handler = self.handler
                Task { await handler(request, responder) }
            } else if isComplete || error != nil || buffer.count > 16 * 1024 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// Parses a complete request, or returns nil while headers or body are still incomplete.
    private static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return nil }

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        return HTTPRequest(
            method: String(requestLine[0]),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: Data(body.prefix(length))
        )
    }
}

/// Resumes a continuation once, whatever state updates follow.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isSet { return false }
        isSet = true
        return true
    }
}
#endif
