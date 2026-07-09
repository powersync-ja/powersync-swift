import AsyncAlgorithms
import Foundation
@testable import PowerSync
import Testing

final class MockHttpClient: HttpClient {
    private let _writeCheckpoint = PowerSync.Mutex(1000)
    /// Request paths observed by the mock, useful when tests need to assert call order.
    private let _requestPaths = PowerSync.Mutex<[String]>([])
    let handleSyncLines: @Sendable (_ request: URLRequest) async throws -> AsyncThrowingChannel<PowerSync.SyncLine, any Error>
    /// Handles `/sync/checkpoint-request` after the mock decodes and validates the request body.
    let checkpointRequestHook: @Sendable (_ request: MockCheckpointRequest) async throws -> MockCheckpointRequestResponse
    
    var writeCheckpoint: Int {
        get {
            _writeCheckpoint.withLock { $0 }
        }
        set {
            _writeCheckpoint.withLock { $0 = newValue }
        }
    }

    var requestPaths: [String] {
        _requestPaths.withLock { $0 }
    }
    
    init(
        handleSyncLines: @Sendable @escaping (_ request: URLRequest) async throws -> AsyncThrowingChannel<PowerSync.SyncLine, any Error>,
        checkpointRequestHook: @Sendable @escaping (_ request: MockCheckpointRequest) async throws -> MockCheckpointRequestResponse = { request in
            .checkpointRequestId(request.requestId)
        }
    ) {
        self.handleSyncLines = handleSyncLines
        self.checkpointRequestHook = checkpointRequestHook
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
            let body = try StreamingSyncClient.jsonDecoder.decode(CheckpointRequestPayload.self, from: data)
            #expect(!body.client_id.isEmpty)
            let requestId = try #require(Int64(body.checkpoint_request_id))
            #expect(requestId > 0)
            let checkpointRequest = MockCheckpointRequest(clientId: body.client_id, requestId: requestId)

            switch try await checkpointRequestHook(checkpointRequest) {
            case .checkpointRequestId(let checkpointRequestId):
                let responseData = try encodeCheckpointRequestResponse(checkpointRequestId)
                let response = HTTPURLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: responseData.count, textEncodingName: "utf-8")
                return (response, responseData)
            case .statusCode(let statusCode):
                let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

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

    private func encodeCheckpointRequestResponse(_ checkpointRequestId: Int64) throws -> Data {
        let response = CheckpointRequestResponse(
            data: CheckpointRequestResponseData(checkpoint_request_id: String(checkpointRequestId))
        )
        return try StreamingSyncClient.jsonEncoder.encode(response)
    }
}

struct MockCheckpointRequest: Sendable {
    let clientId: String
    let requestId: Int64
}

enum MockCheckpointRequestResponse: Sendable {
    case checkpointRequestId(Int64)
    case statusCode(Int)
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
