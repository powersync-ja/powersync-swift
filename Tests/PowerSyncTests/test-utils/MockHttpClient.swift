import AsyncAlgorithms
import Foundation
@testable import PowerSync
import Testing
import Synchronization

final class MockHttpClient: HttpClient {
    let writeCheckpoint: Atomic<Int32> = Atomic(1000)
    let handleSyncLines: @Sendable (_ body: JsonParam) async throws -> AsyncThrowingChannel<PowerSync.SyncLine, any Error>

    init(handleSyncLines: @Sendable @escaping (_ body: JsonParam) async throws -> AsyncThrowingChannel<PowerSync.SyncLine, any Error>) {
        self.handleSyncLines = handleSyncLines
    }
    
    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any Sendable & AsyncSequence<PowerSync.SyncLine, any Error>) {
        try #require(request.url?.path() == "/sync/stream")

        let body = try StreamingSyncClient.jsonDecoder.decode(JsonParam.self, from: try #require(request.httpBody))
        let channel = try await handleSyncLines(body)
        let response = HTTPURLResponse(url: request.url!, mimeType: "application/x-ndjson", expectedContentLength: 0, textEncodingName: "utf-8")

        return (response, channel)
    }
    
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        // The sync client only uses this method to get /write-checkpoint2.json.
        try #require(request.url?.path() == "/write-checkpoint2.json")

        let checkpoint = writeCheckpoint.load(ordering: .sequentiallyConsistent)
        let body = WriteCheckpointResponse(data: WriteCheckpointData(write_checkpoint: String(checkpoint)))

        let data = try StreamingSyncClient.jsonEncoder.encode(body)
        let response = HTTPURLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: "utf-8")

        return (response, data)
    }
}
