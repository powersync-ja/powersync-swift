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
    /// Set when the database is shared with other processes, in which case writes also append
    /// the tables they changed to the update log and notify the other processes.
    private let updateLog: CrossProcessUpdateLog?

    init(
        writer: consuming RawSqliteConnection,
        readers: consuming RigidDeque<RawSqliteConnection>,
        logger: any LoggerProtocol,
        updateLog: CrossProcessUpdateLog? = nil,
        handleUpdates: @escaping @Sendable (_: Set<String>) -> (),
    ) {
        self.writer = AsyncSemaphore(singleElement: writer)
        self.readers = AsyncSemaphore(readers)
        self.handleUpdates = handleUpdates
        self.logger = logger
        self.updateLog = updateLog
    }
    
    init(
        singleConnection: consuming RawSqliteConnection,
        logger: any LoggerProtocol,
        updateLog: CrossProcessUpdateLog? = nil,
        handleUpdates: @escaping @Sendable (_: Set<String>) -> (),
    ) {
        self.writer = AsyncSemaphore(singleElement: singleConnection)
        self.readers = nil
        self.handleUpdates = handleUpdates
        self.logger = logger
        self.updateLog = updateLog
    }

    private func dispatchWrites(lease: NativeConnectionLease) {
        do {
            try lease.withIterator(sql: "SELECT powersync_update_hooks('get')", parameters: []) { rows in
                guard var affectedTables = try rows.next(callback: {
                    let decoder = JSONDecoder()
                    return try decoder.decode(Set<String>.self, from: try $0.getString(index: 0).data(using: .utf8)!)
                }) else {
                    return
                }

                // Our own writes to the update log must not feed back into the machinery.
                affectedTables.remove(CrossProcessUpdateLog.tableName)
                guard !affectedTables.isEmpty else {
                    return
                }

                self.handleUpdates(affectedTables)
                if let updateLog, updateLog.record(tables: affectedTables, lease: lease) {
                    updateLog.signal.post()
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
        let lease = try connection.acquiredItems[0].asLease()
        return try await onConnection(lease)
    }

    func write<T>(onConnection: (NativeConnectionLease) async throws -> T) async throws -> T {
        let connection = try await writer.acquire(count: 1)
        let lease = try connection.acquiredItems[0].asLease()
        defer { dispatchWrites(lease: lease) }
        let result = try await onConnection(lease)
        return result
    }
    
    func withAllConnections<T>(onConnection: (NativeConnectionLease, [NativeConnectionLease]) async throws -> T) async throws -> T {
        let write = try await writer.acquire(count: 1)
        let writeLease = try write.acquiredItems[0].asLease()
        defer { dispatchWrites(lease: writeLease) }

        let result: T
        if let readers {
            let acquiredReaders = try await readers.acquire(count: readers.count)
            var readerLeases: [NativeConnectionLease] = []
            
            let span = acquiredReaders.acquiredItems.span
            for idx in span.indices {
                readerLeases.append(try span[idx].asLease())
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
    
    func asLease() throws(PowerSyncError) -> NativeConnectionLease {
        if closed {
            throw .databaseClosedError()
        }

        return NativeConnectionLease(pointer: self.connection)
    }
}

// We mark this as Sendable because it's only used in a mutex from `ConnectionLeaseContext`.
// We can't generally assume SQLite connections to be thread-safe.
struct NativeConnectionLease: SQLiteConnectionLease, @unchecked Sendable {
    let pointer: OpaquePointer
}
