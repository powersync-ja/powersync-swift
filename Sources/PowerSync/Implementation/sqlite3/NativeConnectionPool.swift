import CSQLite
import Foundation
import DequeModule

/// A helper implementing a SQLite connection pool from opened and configured connections.
///
/// This class does not configure or open connections (that is the responsibility of ``AsyncConnectionPool``).
final class NativeConnectionPool: Sendable {
    // This could be an async mutex, but AsyncSemaphore has better cancellation support.
    private let writer: AsyncSemaphore<RawSqliteConnection>
    private let readers: AsyncSemaphore<RawSqliteConnection>?
    private let handleUpdates: @Sendable (_: Set<String>) -> ()
    private let logger: any LoggerProtocol

    init(
        writer: consuming RawSqliteConnection,
        readers: consuming RigidDeque<RawSqliteConnection>,
        logger: any LoggerProtocol,
        handleUpdates: @escaping @Sendable (_: Set<String>) -> (),
    ) {
        self.writer = AsyncSemaphore(singleElement: writer)
        self.readers = AsyncSemaphore(readers)
        self.handleUpdates = handleUpdates
        self.logger = logger
    }
    
    init(
        singleConnection: consuming RawSqliteConnection,
        logger: any LoggerProtocol,
        handleUpdates: @escaping @Sendable (_: Set<String>) -> (),
    ) {
        self.writer = AsyncSemaphore(singleElement: singleConnection)
        self.readers = nil
        self.handleUpdates = handleUpdates
        self.logger = logger
    }

    private func dispatchWrites(lease: NativeConnectionLease) {
        do {
            try lease.withIterator(sql: "SELECT powersync_update_hooks('get')", parameters: []) { rows in
                let affectedTables = try rows.next {
                    let decoder = JSONDecoder()
                    return try decoder.decode(Set<String>.self, from: try $0.getString(index: 0).data(using: .utf8)!)
                }

                if let affectedTables, !affectedTables.isEmpty {
                    self.handleUpdates(affectedTables)
                }
            }
        } catch {
            logger.warning("Could not read affected tables", tag: "NativeConnectionPool")
        }
    }

    func read<T>(onConnection: (NativeConnectionLease) async throws -> T) async throws -> T {
        // No dedicated readers? Acquire write connection for this then
        let semaphore = readers ?? writer
        let connection = try await semaphore.acquire(count: 1)
        let lease = connection.acquiredItems[0].asLease()
        return try await onConnection(lease)
    }

    func write<T>(onConnection: (NativeConnectionLease) async throws -> T) async throws -> T {
        let connection = try await writer.acquire(count: 1)
        let lease = connection.acquiredItems[0].asLease()
        defer { dispatchWrites(lease: lease) }
        let result = try await onConnection(lease)
        return result
    }
    
    func withAllConnections<T>(onConnection: (NativeConnectionLease, [NativeConnectionLease]) async throws -> T) async throws -> T {
        let write = try await writer.acquire(count: 1)
        let writeLease = write.acquiredItems[0].asLease()
        defer { dispatchWrites(lease: writeLease) }

        let result: T
        if let readers {
            let acquiredReaders = try await readers.acquire(count: readers.count)
            var readerLeases: [NativeConnectionLease] = []
            
            let span = acquiredReaders.acquiredItems.span
            for idx in span.indices {
                readerLeases.append(span[idx].asLease())
            }
            result = try await onConnection(writeLease, readerLeases)
        } else {
            result = try await onConnection(writeLease, [])
        }
        return result
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
        if var span = acquiredReaders?.acquiredItems.mutableSpan {
            for idx in span.indices {
                span[idx].close()
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
    
    func asLease() -> NativeConnectionLease {
        precondition(!closed)
        return NativeConnectionLease(pointer: self.connection)
    }
}

// We mark this as Sendable because it's only used in a mutex from `ConnectionLeaseContext`.
// We can't generally assume SQLite connections to be thread-safe.
struct NativeConnectionLease: SQLiteConnectionLease, @unchecked Sendable {
    let pointer: OpaquePointer

    func execute(sql: String, parameters: [PowerSyncDataType?]) throws -> Int64 {
        do {
            var stmt = try NativeSqliteStatement(db: pointer, sql: sql)
            try stmt.bindValues(parameters)
            while try stmt.step() {
                // Iterate through the statement.
            }
        }

        return sqlite3_changes64(pointer)
    }

    func withIterator<T>(sql: String, parameters: [PowerSyncDataType?], callback: (SQLiteStatementIteratorProtocol) throws -> T) throws -> T {
        var stmt = try NativeSqliteStatement(db: pointer, sql: sql)
        try stmt.bindValues(parameters)
        return try withUnsafeMutablePointer(to: &stmt) { ptr in
            let iterator = NativeStatementIterator(stmt: ptr)
            return try callback(iterator)
        }
    }
}

private struct NativeStatementIterator: SQLiteStatementIteratorProtocol {
    var stmt: UnsafeMutablePointer<NativeSqliteStatement>
    
    func next<T>(callback: (any SqlCursor) throws -> T) throws -> T? {
        if try stmt.pointee.step() {
            let cursor = StatementCursor(stmt)
            defer { cursor.invalidate() }
            return try callback(cursor)
        } else {
            return nil
        }
    }
}
