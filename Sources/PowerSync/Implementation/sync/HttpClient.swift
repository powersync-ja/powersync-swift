import Foundation

/// A protocol exposing parts of ``URLSession`` so that it can be mocked in tests.
protocol PowerSyncUrlSession: Sendable where Response: AsyncSequence, Response: Sendable, Response.Element == UInt8 {
    associatedtype Response
    
    /// Start streaming a `/sync/stream` response body, emitting individual lines.
    ///
    /// Throws an ``UnexpectedResponseError`` if the response can't be interpreted as sync lines.
    func readStreamed(request: URLRequest) async throws -> (HTTPURLResponse, Response)
    
    /// Read a full response body.
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data)
}


extension URLSession: PowerSyncUrlSession {
    typealias Response = AsyncBytes

    func readStreamed(request: URLRequest) async throws -> (HTTPURLResponse, Response) {
        let (bytes, originalResponse) = try await self.bytes(for: request)
        return (originalResponse as! HTTPURLResponse, bytes)
    }

    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await self.data(for: request)
        return (response as! HTTPURLResponse, data)
    }
}

extension PowerSyncUrlSession {
    var client: HttpClient {
        let client = SpecializedHttpClient<Self>(session: self)
        return HttpClient.init(client)
    }
}

/// An internal HTTP client implementation.
/// 
/// This only exposes HTTP functionality required by the sync client, it is not a general-purpose
/// HTTP client.
struct HttpClient {
    // Use closures to keep the actual client specialized for the real / mocked url session.
    private let _receiveSyncLines: @Sendable (URLRequest, SyncRequestLoggerConfiguration?) async throws -> (HTTPURLResponse, SyncLineResponse)
    private let _readFully: @Sendable (URLRequest, SyncRequestLoggerConfiguration?) async throws -> (HTTPURLResponse, Data)

    fileprivate init<Session: PowerSyncUrlSession>(_ client: SpecializedHttpClient<Session>) {
        _receiveSyncLines = { try await client.receiveSyncLines(request: $0, logger: $1) }
        _readFully = { try await client.readFully(request: $0, logger: $1) }
    }

    func receiveSyncLines(request: URLRequest, logger: SyncRequestLoggerConfiguration?) async throws -> (HTTPURLResponse, SyncLineResponse) {
        try await _receiveSyncLines(request, logger)
    }
    func readFully(request: URLRequest, logger: SyncRequestLoggerConfiguration?) async throws -> (HTTPURLResponse, Data) {
        try await _readFully(request, logger)
    }
}

struct SpecializedHttpClient<Session: PowerSyncUrlSession> {
    let session: Session

    func receiveSyncLines(request: URLRequest, logger: SyncRequestLoggerConfiguration?) async throws -> (HTTPURLResponse, SyncLineResponse) {
        logger?.logRequest(request: request)
        do {
            let (response, bytes) = try await session.readStreamed(request: request)
            logger?.logResponse(response: response)
            let jsonStreamMimeType = "application/x-ndjson"

            if response.mimeType != jsonStreamMimeType {
                throw UnexpectedResponseError(
                    response: response,
                    message: "Invalid sync lines response, (expected \(jsonStreamMimeType), got \(response.mimeType, default: "")"
                )
            }

            return (response, SyncLineResponse(SpecializedSyncLineResponse<Session.Response>(source: bytes, logging: logger)))
        } catch {
            logger?.logError(error: error)
            throw error
        }
    }

    func readFully(request: URLRequest, logger: SyncRequestLoggerConfiguration?) async throws -> (HTTPURLResponse, Data) {
        logger?.logRequest(request: request)
        do {
            let (response, data) = try await session.readFully(request: request)
            logger?.logResponse(response: response)
            if let logger, logger.shouldLogBody, let content = String(data: data, encoding: .utf8) {
                logger.log("  Response: \(content)")
            }
            return (response, data)
        } catch {
            logger?.logError(error: error)
            throw error
        }
    }
}

struct UnexpectedResponseError: Error, CustomDebugStringConvertible {
    let response: HTTPURLResponse
    let message: String

    var debugDescription: String {
        message
    }
}

struct UnexpectedEndOfStreamError: Error, CustomDebugStringConvertible {
    var debugDescription: String {
        "PowerSync streamed response ended unexpectedly in the middle of a line"
    }
}


/// A response to a `/sync/stream` request, split into individual lines.
struct SyncLineResponse: AsyncSequence, Sendable {
    typealias Element = SyncLine

    private let _makeAsyncIterator: @Sendable () -> SyncLineResponseIterator

    fileprivate init<Source: AsyncSequence & Sendable>(_ response: SpecializedSyncLineResponse<Source>) where Source.Element == UInt8 {
        _makeAsyncIterator = { SyncLineResponseIterator(response.makeAsyncIterator()) }
    }

    func makeAsyncIterator() -> SyncLineResponseIterator {
        _makeAsyncIterator()
    }
}

struct SyncLineResponseIterator: AsyncIteratorProtocol {
    typealias Element = SyncLine

    private let _next: () async throws -> SyncLine?

    fileprivate init<Source: AsyncSequence>(_ iterator: SpecializedSyncLineResponseIterator<Source>) where Source.Element == UInt8 {
        var iterator = iterator
        _next = { try await iterator.next() }
    }

    mutating func next() async throws -> SyncLine? {
        try await _next()
    }
}

private struct SpecializedSyncLineResponse<Source: AsyncSequence & Sendable> where Source.Element == UInt8 {
    let source: Source
    let logging: SyncRequestLoggerConfiguration?

    func makeAsyncIterator() -> SpecializedSyncLineResponseIterator<Source> {
        return SpecializedSyncLineResponseIterator<Source>(source: source.makeAsyncIterator(), logging: logging)
    }
}

private struct SpecializedSyncLineResponseIterator<Source: AsyncSequence> where Source.Element == UInt8 {
    // Note: Keep this generic to specialize next().
    var source: Source.AsyncIterator
    var logging: SyncRequestLoggerConfiguration?
    var buffer: Array<UInt8> = []

    mutating func next() async throws -> SyncLine? {
        // Read a line from the response stream. This doesn't use AsyncLineSequence as that splits on other
        // unicode characters (like \u2028) as well, which the service includes in responses without escaping.
        let line = try await readLine()
        if let logging, logging.shouldLogBody {
            if let line {
                logging.log("Response line: \(line)")
            } else {
                logging.log("End of response")
            }
        }

        return line.map { SyncLine.text(contents: $0) }
    }

    private mutating func takeLineFromBuffer() -> String? {
        if buffer.isEmpty {
            return nil
        }

        defer {
            buffer.removeAll(keepingCapacity: true)
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    private mutating func readLine() async throws -> String? {
        while let first = try await source.next() {
            switch first {
            case 10: // \n
                guard let result = takeLineFromBuffer() else {
                    continue
                }
                return result
            default:
                buffer.append(first)
            }
        }

        if buffer.isEmpty {
            return nil
        }

        // The stream ended in the middle of a line (no trailing \n was seen), so we can't tell whether
        // the last line we received is complete. Report this as an error instead of returning a
        // possibly-truncated line.
        throw UnexpectedEndOfStreamError()
    }
}

enum SyncLine {
    case text(contents: String)
    // In the future, we might also want to support splitting BSON objects. Currently, we stream JSON only.
    //case binary(contents: Data)
}

fileprivate extension SyncRequestLoggerConfiguration {
    var shouldLogInfo: Bool {
        requestLevel != .none
    }

    var shouldLogHeaders: Bool {
        requestLevel == .all || requestLevel == .headers
    }
    
    var shouldLogBody: Bool {
        requestLevel == .all || requestLevel == .body
    }

    func logRequest(request: URLRequest) {
        if shouldLogInfo, let method = request.httpMethod, let url = request.url {
            log("Starting request to \(method) \(url)")
        }

        if shouldLogHeaders, let headers = request.allHTTPHeaderFields {
            for (key, value) in headers {
                log("with header \(key): \(value)")
            }
        }

        if shouldLogBody, let rawBody = request.httpBody, let body = String(data: rawBody, encoding: .utf8) {
            log("with body: \(body)")
        }

        if shouldLogInfo {
            log("sending request")
        }
    }

    func logResponse(response: HTTPURLResponse) {
        if shouldLogInfo, let url = response.url {
            log("Got response code \(response.statusCode) on \(url)")
        }
        
        if shouldLogHeaders {
            for (key, value) in response.allHeaderFields {
                log("with header \(key): \(value)")
            }
        }
    }

    func logError(error: any Error) {
        if shouldLogInfo {
            log("Error: \(error)")
        }
    }
}
