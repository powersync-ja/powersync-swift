import AsyncAlgorithms
import Foundation
@testable import PowerSync
import Testing

final class MockHttpClient: HttpClient {
    private let _writeCheckpoint = PowerSync.Mutex(1000)
    private let _checkpointRequestIds = PowerSync.Mutex<[Int64]>([])
    private let _checkpointRequestResponse = PowerSync.Mutex<Int64?>(nil)
    private let _checkpointRequestFailuresRemaining = PowerSync.Mutex(0)
    let handleSyncLines: @Sendable (_ request: URLRequest) async throws -> AsyncThrowingChannel<PowerSync.SyncLine, any Error>
    
    var writeCheckpoint: Int {
        get {
            _writeCheckpoint.withLock { $0 }
        }
        set {
            _writeCheckpoint.withLock { $0 = newValue }
        }
    }

    var checkpointRequestIds: [Int64] {
        _checkpointRequestIds.withLock { $0 }
    }

    var checkpointRequestResponse: Int64? {
        get {
            _checkpointRequestResponse.withLock { $0 }
        }
        set {
            _checkpointRequestResponse.withLock { $0 = newValue }
        }
    }

    var checkpointRequestFailuresRemaining: Int {
        get {
            _checkpointRequestFailuresRemaining.withLock { $0 }
        }
        set {
            _checkpointRequestFailuresRemaining.withLock { $0 = newValue }
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
        let path = try #require(request.url?.path)

        switch path {
        case "/sync/checkpoint-request":
            try #require(request.httpMethod == "POST")

            let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
            #expect(contentType.hasPrefix("application/json"))

            let data = try #require(request.httpBody)
            let body = try StreamingSyncClient.jsonDecoder.decode(CheckpointRequestBody.self, from: data)
            #expect(!body.client_id.isEmpty)
            #expect(body.checkpoint_request_id > 0)
            _checkpointRequestIds.withLock { $0.append(body.checkpoint_request_id) }

            let shouldFail = _checkpointRequestFailuresRemaining.withLock { failures in
                if failures > 0 {
                    failures -= 1
                    return true
                }

                return false
            }
            if shouldFail {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            let checkpoint = checkpointRequestResponse ?? body.checkpoint_request_id
            let responseBody = WriteCheckpointData(write_checkpoint: String(checkpoint))
            let responseData = try StreamingSyncClient.jsonEncoder.encode(responseBody)
            let response = HTTPURLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: responseData.count, textEncodingName: "utf-8")
            return (response, responseData)

        case "/write-checkpoint2.json":
            let checkpoint = writeCheckpoint
            let body = WriteCheckpointResponse(data: WriteCheckpointData(write_checkpoint: String(checkpoint)))

            let data = try StreamingSyncClient.jsonEncoder.encode(body)
            let response = HTTPURLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: "utf-8")

            return (response, data)

        default:
            throw PowerSyncError.operationFailed(message: "Unsupported mock request path: \(path)")
        }
    }
}

private struct CheckpointRequestBody: Decodable {
    let client_id: String
    let checkpoint_request_id: Int64
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
