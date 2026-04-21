import AsyncAlgorithms
import Foundation
@testable import PowerSync
import Testing
import Synchronization

final class MockHttpClient: HttpClient {
    private let _writeCheckpoint = PowerSync.Mutex(1000)
    let handleSyncLines: @Sendable (_ request: URLRequest) async throws -> AsyncThrowingChannel<PowerSync.SyncLine, any Error>
    
    var writeCheckpoint: Int {
        get {
            _writeCheckpoint.withLock { $0 }
        }
        set {
            _writeCheckpoint.withLock { $0 = newValue }
        }
    }
    
    init(handleSyncLines: @Sendable @escaping (_ request: URLRequest) async throws -> AsyncThrowingChannel<PowerSync.SyncLine, any Error>) {
        self.handleSyncLines = handleSyncLines
    }
    
    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any SyncLineResponse) {
        try #require(request.url?.path == "/sync/stream")

        let channel = try await handleSyncLines(request)
        let response = HTTPURLResponse(url: request.url!, mimeType: "application/x-ndjson", expectedContentLength: 0, textEncodingName: "utf-8")

        return (response, MockSyncLineResponse(inner: channel))
    }
    
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        // The sync client only uses this method to get /write-checkpoint2.json.
        try #require(request.url?.path == "/write-checkpoint2.json")

        let checkpoint = writeCheckpoint
        let body = WriteCheckpointResponse(data: WriteCheckpointData(write_checkpoint: String(checkpoint)))

        let data = try StreamingSyncClient.jsonEncoder.encode(body)
        let response = HTTPURLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: "utf-8")

        return (response, data)
    }
}

private struct MockSyncLineResponse: SyncLineResponse {
    let inner: AsyncThrowingChannel<PowerSync.SyncLine, any Error>
    
    func makeAsyncIterator() -> MockSyncLineResponseIterator {
        return MockSyncLineResponseIterator(inner: inner.makeAsyncIterator())
    }
}

private struct MockSyncLineResponseIterator: SyncLineResponseIterator {
    var inner: AsyncThrowingChannel<PowerSync.SyncLine, any Error>.AsyncIterator
    
    mutating func next() async throws -> PowerSync.SyncLine? {
        return try await inner.next()
    }
}
