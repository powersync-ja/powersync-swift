import Foundation

/// An internal protocol for HTTP clients, we use this to mock clients in tests.
protocol HttpClient: Sendable {
    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any AsyncSequence<SyncLine, any Error> & Sendable)
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data)
}

enum SyncLine {
    case text(contents: String)
    // In the future, we might also want to support splitting BSON objects. Currently, we stream JSON only.
    //case binary(contents: Data)
}

struct PlatformHttpClient: HttpClient {
    let session: URLSession
    
    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any AsyncSequence<SyncLine, any Error> & Sendable) {
        let (bytes, response) = try await session.bytes(for: request)
        let jsonStreamMimeType = "application/x-ndjson"
        
        if response.mimeType != jsonStreamMimeType {
            throw PowerSyncError.operationFailed(message: "Invalid sync lines response, (expected \(jsonStreamMimeType), got \(response.mimeType, default: "")")
        }
        
        let syncLines = bytes.lines.map { line in SyncLine.text(contents: line) }
        return (response as! HTTPURLResponse, syncLines)
    }
    
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        return (response as! HTTPURLResponse, data)
    }
    
    static let shared = PlatformHttpClient(session: .shared)
}
