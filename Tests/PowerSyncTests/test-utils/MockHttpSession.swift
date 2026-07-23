import AsyncAlgorithms
import Foundation
@testable import PowerSync
import Testing

final class MockHttpSession: PowerSyncUrlSession {
    typealias Response = ChunksToBytes

    private let _writeCheckpoint = PowerSync.Mutex(1000)
    let handleSyncLines: @Sendable (_ request: URLRequest) async throws -> AsyncThrowingChannel<Data, any Error>
    
    var writeCheckpoint: Int {
        get {
            _writeCheckpoint.withLock { $0 }
        }
        set {
            _writeCheckpoint.withLock { $0 = newValue }
        }
    }
    
    init(handleSyncLines: @Sendable @escaping (_ request: URLRequest) async throws -> AsyncThrowingChannel<Data, any Error>) {
        self.handleSyncLines = handleSyncLines
    }

    func readStreamed(request: URLRequest) async throws -> (HTTPURLResponse, Response) {
        try #require(request.url?.path == "/sync/stream")

        let channel = try await handleSyncLines(request)
        let response = HTTPURLResponse(url: request.url!, mimeType: "application/x-ndjson", expectedContentLength: 0, textEncodingName: "utf-8")

        return (response, ChunksToBytes(stream: channel))
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
