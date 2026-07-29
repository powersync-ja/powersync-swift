import AsyncAlgorithms
import Foundation
@testable import PowerSync
import Testing

final class MockHttpSession: PowerSyncUrlSession {
    typealias Response = ChunksToBytes

    private let _writeCheckpoint = PowerSync.Mutex(1000)
    private let _requestPaths = PowerSync.Mutex<[String]>([])
    let handleSyncLines: @Sendable (_ request: URLRequest) async throws -> AsyncThrowingChannel<Data, any Error>
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
        handleSyncLines: @Sendable @escaping (_ request: URLRequest) async throws -> AsyncThrowingChannel<Data, any Error>,
        checkpointRequestHook: @Sendable @escaping (_ request: MockCheckpointRequest) async throws -> MockCheckpointRequestResponse = { request in
            .checkpointRequestId(request.requestId)
        }
    ) {
        self.handleSyncLines = handleSyncLines
        self.checkpointRequestHook = checkpointRequestHook
    }

    func readStreamed(request: URLRequest) async throws -> (HTTPURLResponse, Response) {
        try #require(request.url?.path == "/sync/stream")
        _requestPaths.withLock { $0.append("/sync/stream") }

        let channel = try await handleSyncLines(request)
        let response = HTTPURLResponse(url: request.url!, mimeType: "application/x-ndjson", expectedContentLength: 0, textEncodingName: "utf-8")

        return (response, ChunksToBytes(stream: channel))
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
            let requestId = body.checkpoint_request_id
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
            let body = WriteCheckpointResponse(data: WriteCheckpointData(write_checkpoint: Int64(checkpoint)))
            let data = try StreamingSyncClient.jsonEncoder.encode(body)
            let response = HTTPURLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: "utf-8")
            return (response, data)

        default:
            throw PowerSyncError.operationFailed(message: "Unsupported mock request path: \(path)")
        }
    }

    private func encodeCheckpointRequestResponse(_ checkpointRequestId: Int64) throws -> Data {
        let response = CheckpointRequestResponse(
            data: CheckpointRequestResponseData(checkpoint_request_id: checkpointRequestId)
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

/// Flattens a sequence of byte chunks into a sequence of bytes.
struct ChunksToBytes: AsyncSequence {
    typealias Element = UInt8
    typealias AsyncIterator = Iterator

    let stream: AsyncThrowingChannel<Data, any Error>

    struct Iterator: AsyncIteratorProtocol {
        typealias Element = UInt8

        var stream: AsyncThrowingChannel<Data, any Error>.AsyncIterator
        var buffer: Data?
        var offset: Int = 0

        mutating func next() async throws -> UInt8? {
            if let buffer {
                return readFromBuffer(buffer: buffer)
            }

            guard let line = try await stream.next() else { return nil }
            buffer = line
            offset = 0
            return readFromBuffer(buffer: line)
        }

        mutating func readFromBuffer(buffer: Data) -> UInt8 {
            let byte = buffer[offset]
            offset += 1
            if offset == buffer.count {
                self.buffer = nil
            }
            return byte
        }
    }

    func makeAsyncIterator() -> Iterator {
        return Iterator(stream: stream.makeAsyncIterator())
    }
}
