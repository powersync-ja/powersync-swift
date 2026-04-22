import CSQLite
import Foundation
import DequeModule

/// A helper implementing a SQLite connection pool from opened and configured connections.
///
/// This class does not configure or open connections (that is the responsibility of ``AsyncConnectionPool``).
final class NativeConnectionPool: Sendable {
    private let writer: AsyncSemaphore<RawSqliteConnection>
    private let readers: AsyncSemaphore<RawSqliteConnection>?
    private let handleUpdates: @Sendable (_: Set<String>) -> ()

    init(writer: consuming RawSqliteConnection, readers: consuming RigidDeque<RawSqliteConnection>, handleUpdates: @escaping @Sendable (_: Set<String>) -> ()) {
        self.writer = AsyncSemaphore(singleElement: writer)
        self.readers = AsyncSemaphore(readers)
        self.handleUpdates = handleUpdates
    }
    
    init(singleConnection: consuming RawSqliteConnection, handleUpdates: @escaping @Sendable (_: Set<String>) -> ()) {
        self.writer = AsyncSemaphore(singleElement: singleConnection)
        self.readers = nil
        self.handleUpdates = handleUpdates
    }

    private func dispatchWrites(lease: RawConnectionLease) throws {
        let ctx = NativeConnectionContext(lease)
        let affectedTables = try ctx.get(sql: "SELECT powersync_update_hooks('get')", parameters: []) {
            let decoder = JSONDecoder()
            return try decoder.decode(Set<String>.self, from: try $0.getString(index: 0).data(using: .utf8)!)
        }

        if !affectedTables.isEmpty {
            self.handleUpdates(affectedTables)
        }
    }

    func read(onConnection: @Sendable (RawConnectionLease) async throws -> Void) async throws {
        // No dedicated readers? Acquire write connection for this then
        let semaphore = readers ?? writer
        let connection = try await semaphore.acquire(count: 1)
        let lease = connection.acquiredItems[0].asLease()
        try await onConnection(lease)
    }

    func write(onConnection: @Sendable (RawConnectionLease) async throws -> Void) async throws {
        let connection = try await writer.acquire(count: 1)
        let lease = connection.acquiredItems[0].asLease()
        try await onConnection(lease)
        try dispatchWrites(lease: lease)
    }
    
    func withAllConnections(onConnection: @Sendable (RawConnectionLease, [RawConnectionLease]) async throws -> Void) async throws {
        let write = try await writer.acquire(count: 1)
        let writeLease = write.acquiredItems[0].asLease()
        if let readers {
            let acquiredReaders = try await readers.acquire(count: readers.count)
            var readerLeases: [RawConnectionLease] = []
            var i = 0
            while i < acquiredReaders.acquiredItems.count {
                readerLeases.append(write.acquiredItems[i].asLease())
                i += 1
            }

            try await onConnection(writeLease, readerLeases)
        } else {
            try await onConnection(writeLease, [])
        }
        
        try dispatchWrites(lease: writeLease)
    }
    
    func close() async throws {
        // First, lock all connections
        var write = try await writer.acquire(count: 1)
        var acquiredReaders: SemaphoreGrant<RawSqliteConnection>? = nil
        if let readers {
            acquiredReaders = try await readers.acquire(count: readers.count)
        }
        
        // Close the write connection first
        write.acquiredItems[0].close()
        if var acquiredReaders {
            var i = 0
            while i < acquiredReaders.acquiredItems.count {
                acquiredReaders.acquiredItems[i].close()
                i += 1
            }
        }
    }
}

struct RawSqliteConnection: ~Copyable {
    let connection: OpaquePointer
    var closed = false

    deinit {
        if !closed {
            closeInner()
        }
    }
    
    mutating func close() {
        if !closed {
            closeInner()
            closed = true
        }
    }
    
    private func closeInner() {
        sqlite3_close_v2(connection)
    }
    
    func asLease() -> RawConnectionLease {
        precondition(!closed)
        return RawConnectionLease(pointer: self.connection)
    }
}

struct RawConnectionLease: SQLiteConnectionLease, @unchecked Sendable {
    let pointer: OpaquePointer
}
