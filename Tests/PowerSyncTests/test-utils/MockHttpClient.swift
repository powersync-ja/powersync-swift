import AsyncAlgorithms
import Foundation
@testable import PowerSync
import Testing

final class MockHttpClient: HttpClient {
    private let _writeCheckpoint = PowerSync.Mutex(1000)
    private let _checkpointRequestIds = PowerSync.Mutex<[Int64]>([])
    private let _checkpointRequestResponse = PowerSync.Mutex<Int64?>(nil)
    private let _checkpointRequestStateResponses = PowerSync.Mutex<[Int64?]>([])
    private let _checkpointRequestStateHints = PowerSync.Mutex<[Int64?]>([])
    private let _checkpointRequestFailuresRemaining = PowerSync.Mutex(0)
    private let _checkpointRequestFailureStatusCode = PowerSync.Mutex(500)
    private let _requestPaths = PowerSync.Mutex<[String]>([])
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

    var checkpointRequestStateResponse: Int64? {
        get {
            _checkpointRequestStateResponses.withLock { $0.first ?? nil }
        }
        set {
            _checkpointRequestStateResponses.withLock { $0 = [newValue] }
        }
    }

    var checkpointRequestStateResponses: [Int64?] {
        get {
            _checkpointRequestStateResponses.withLock { $0 }
        }
        set {
            _checkpointRequestStateResponses.withLock { $0 = newValue }
        }
    }

    var checkpointRequestStateHints: [Int64?] {
        _checkpointRequestStateHints.withLock { $0 }
    }

    var checkpointRequestFailuresRemaining: Int {
        get {
            _checkpointRequestFailuresRemaining.withLock { $0 }
        }
        set {
            _checkpointRequestFailuresRemaining.withLock { $0 = newValue }
        }
    }

    var checkpointRequestFailureStatusCode: Int {
        get {
            _checkpointRequestFailureStatusCode.withLock { $0 }
        }
        set {
            _checkpointRequestFailureStatusCode.withLock { $0 = newValue }
        }
    }

    var requestPaths: [String] {
        _requestPaths.withLock { $0 }
    }
    
    init(handleSyncLines: @Sendable @escaping (_ request: URLRequest) async throws -> AsyncThrowingChannel<PowerSync.SyncLine, any Error>) {
        self.handleSyncLines = handleSyncLines
    }
    
    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any SyncLineResponse) {
        try #require(request.url?.path == "/sync/stream")
        _requestPaths.withLock { $0.append("/sync/stream") }

        let channel = try await handleSyncLines(request)
        let response = HTTPURLResponse(url: request.url!, mimeType: "application/x-ndjson", expectedContentLength: 0, textEncodingName: "utf-8")

        return (response, MockSyncLineResponse(inner: channel))
    }
    
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let path = try #require(request.url?.path)
        _requestPaths.withLock { $0.append(path) }

        switch path {
        case "/sync/checkpoint-request":
            try #require(request.httpMethod == "POST")

            let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
            #expect(contentType.hasPrefix("application/json"))

            let data = try #require(request.httpBody)
            let body = try StreamingSyncClient.jsonDecoder.decode(CheckpointRequestBody.self, from: data)
            #expect(!body.client_id.isEmpty)
            let requestId = try #require(Int64(body.checkpoint_request_id))
            #expect(requestId >= 0)
            _checkpointRequestIds.withLock { $0.append(requestId) }
            _checkpointRequestStateHints.withLock { $0.append(requestId) }

            let shouldFail = _checkpointRequestFailuresRemaining.withLock { failures in
                if failures > 0 {
                    failures -= 1
                    return true
                }

                return false
            }
            if shouldFail {
                let statusCode = _checkpointRequestFailureStatusCode.withLock { $0 }
                let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            let configuredStateResponse = _checkpointRequestStateResponses.withLock { responses -> Int64?? in
                responses.isEmpty ? nil : .some(responses.removeFirst())
            }
            let checkpoint: Int64
            if let configuredStateResponse {
                checkpoint = configuredStateResponse ?? requestId
            } else if requestId == 0 {
                checkpoint = requestId
            } else {
                checkpoint = checkpointRequestResponse ?? requestId
            }
            let responseData = try encodeWriteCheckpointResponse(checkpoint)
            let response = HTTPURLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: responseData.count, textEncodingName: "utf-8")
            return (response, responseData)

        case "/write-checkpoint2.json":
            let checkpoint = writeCheckpoint
            let data = try encodeWriteCheckpointResponse(Int64(checkpoint))
            let response = HTTPURLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: "utf-8")

            return (response, data)

        default:
            throw PowerSyncError.operationFailed(message: "Unsupported mock request path: \(path)")
        }
    }

    private func encodeWriteCheckpointResponse(_ checkpoint: Int64) throws -> Data {
        let response = WriteCheckpointResponse(data: WriteCheckpointData(write_checkpoint: String(checkpoint)))
        return try StreamingSyncClient.jsonEncoder.encode(response)
    }
}

private struct CheckpointRequestBody: Decodable {
    let client_id: String
    let checkpoint_request_id: String
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
