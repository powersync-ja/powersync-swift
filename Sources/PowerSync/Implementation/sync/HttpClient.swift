import Foundation

/// An internal protocol for HTTP clients.
/// 
/// Outside of tests, this is implemented by ``PlatformHttpClient`` as a thin wrapper around
/// ``URLSession``. In tests, we can use a mock implementation to test the sync client instead.
/// 
/// This is an internal protocol and tailored towards what the sync client actually needs. It is not
/// a general-purpose HTTP client. 
protocol HttpClient: Sendable {
    /// Start streaming a `/sync/stream` response body, emitting individual lines.
    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any SyncLineResponse)

    /// Read a full response body.
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data)
}

protocol SyncLineResponse: Sendable, AsyncSequence where AsyncIterator: SyncLineResponseIterator {}

protocol SyncLineResponseIterator: AsyncIteratorProtocol {
    mutating func next() async throws -> SyncLine?
}

enum SyncLine {
    case text(contents: String)
    // In the future, we might also want to support splitting BSON objects. Currently, we stream JSON only.
    //case binary(contents: Data)
}

struct PlatformHttpClient: HttpClient {
    let session: URLSession
    
    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any SyncLineResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let jsonStreamMimeType = "application/x-ndjson"
        
        if response.mimeType != jsonStreamMimeType {
            throw PowerSyncError.operationFailed(message: "Invalid sync lines response, (expected \(jsonStreamMimeType), got \(response.mimeType, default: "")")
        }

        struct PlatformSyncLineResponse<Base>: SyncLineResponse where Base : AsyncSequence, Base.Element == UInt8, Base: Sendable {
            let lines: AsyncLineSequence<Base>

            func makeAsyncIterator() -> some SyncLineResponseIterator {
                return PlatformSyncLineResponseIterator<Base>(inner: lines.makeAsyncIterator())
            }
        }

        struct PlatformSyncLineResponseIterator<Base>: SyncLineResponseIterator where Base : AsyncSequence, Base.Element == UInt8, Base: Sendable {
            typealias Element = SyncLine

            var inner: AsyncLineSequence<Base>.AsyncIterator

            mutating func next() async throws -> SyncLine? {
                let line = try await inner.next()
                return line.map { SyncLine.text(contents: $0) }
            }
        }

        return (response as! HTTPURLResponse, PlatformSyncLineResponse(lines: bytes.lines))
    }
    
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        return (response as! HTTPURLResponse, data)
    }
    
    static let shared = PlatformHttpClient(session: .shared)
}

/// A wrapper around a ``HttpClient`` emitting log events for responses and sync lines.
struct LoggingClient: HttpClient {
    let inner: HttpClient
    let logger: SyncRequestLoggerConfiguration

    fileprivate var shouldLogInfo: Bool {
        logger.requestLevel != .none
    }
    
    fileprivate var shouldLogHeaders: Bool {
        logger.requestLevel == .all || logger.requestLevel == .headers
    }
    
    fileprivate var shouldLogBody: Bool {
        logger.requestLevel == .all || logger.requestLevel == .body
    }

    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any SyncLineResponse) {
        logRequest(request: request)
        do {
            let (response, lines) = try await inner.receiveSyncLines(request: request)
            logResponse(response: response)
            
            return (response, LogSyncLines(logger: self, inner: lines))
        } catch {
            logError(error: error)
            throw error
        }
    }

    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        logRequest(request: request)
        do {
            let (response, data) = try await inner.readFully(request: request)
            logResponse(response: response)
            if shouldLogBody, let content = String(data: data, encoding: .utf8) {
                logger.log("  Response: \(content)")
            }
            return (response, data)
        } catch {
            logError(error: error)
            throw error
        }
    }
    
    private func logRequest(request: URLRequest) {
        if shouldLogInfo, let method = request.httpMethod, let url = request.url {
            logger.log("Starting request to \(method) \(url)")
        }

        if shouldLogHeaders, let headers = request.allHTTPHeaderFields {
            for (key, value) in headers {
                logger.log("with header \(key): \(value)")
            }
        }
        
        if shouldLogBody, let rawBody = request.httpBody, let body = String(data: rawBody, encoding: .utf8) {
            logger.log("with body: \(body)")
        }
        
        if shouldLogInfo {
            logger.log("sending request")
        }
    }
    
    private func logResponse(response: HTTPURLResponse) {
        if shouldLogInfo, let url = response.url {
            logger.log("Got response code \(response.statusCode) on \(url)")
        }
        
        if shouldLogHeaders {
            for (key, value) in response.allHeaderFields {
                logger.log("with header \(key): \(value)")
            }
        }
    }
    
    private func logError(error: any Error) {
        if shouldLogInfo {
            logger.log("Error: \(error)")
        }
    }
}

private struct LogSyncLines: SyncLineResponse, Sendable {
    typealias AsyncIterator = LogSyncLinesIterator
    
    let logger: LoggingClient
    let inner: any SyncLineResponse

    func makeAsyncIterator() -> LogSyncLinesIterator {
        LogSyncLinesIterator(logger: logger, inner: inner.makeAsyncIterator())
    }
}

private struct LogSyncLinesIterator: SyncLineResponseIterator {
    let logger: LoggingClient
    var inner: any SyncLineResponseIterator
    
    mutating func next() async throws -> SyncLine? {
        let line = try await self.inner.next()
        if logger.shouldLogBody {
            switch line {
            case .none:
                logger.logger.log("End of response")
            case .some(.text(contents: let contents)):
                logger.logger.log("Response line: \(contents)")
            }
        }
        
        return line
    }
}
