import PowerSyncKotlin

class KotlinLeaseAdapter: PowerSyncKotlin.SwiftLeaseAdapter {
    let pointer: UnsafeMutableRawPointer

    init(
        lease: SQLiteConnectionLease
    ) {
        pointer = UnsafeMutableRawPointer(lease.pointer)
    }
}

final class SwiftSQLiteConnectionPoolAdapter: PowerSyncKotlin.SwiftPoolAdapter {
    let pool: SQLiteConnectionPoolProtocol
    var updateTrackingTask: Task<Void, Never>?

    init(
        pool: SQLiteConnectionPoolProtocol
    ) {
        self.pool = pool
    }

    func linkExternalUpdates(callback: any KotlinSuspendFunction1) {
        let sendableCallback = SendableSuspendFunction1(callback)
        updateTrackingTask = Task { [pool] in
            do {
                for try await updates in pool.tableUpdates {
                    _ = try await sendableCallback.invoke(p1: updates)
                }
            } catch {
                // none of these calls should actually throw
            }
        }
    }

    func __dispose() async throws {
        return try await wrapExceptions {
            updateTrackingTask?.cancel()
            updateTrackingTask = nil
        }
    }

    func __leaseRead(callback: any LeaseCallback) async throws {
        return try await wrapExceptions {
            let sendableCallback = SendableLeaseCallback(callback)
            try await pool.read { lease in
                try sendableCallback.execute(
                    lease: KotlinLeaseAdapter(
                        lease: lease
                    )
                )
            }
        }
    }

    func __leaseWrite(callback: any LeaseCallback) async throws {
        return try await wrapExceptions {
            let sendableCallback = SendableLeaseCallback(callback)
            try await pool.write { lease in
                try sendableCallback.execute(
                    lease: KotlinLeaseAdapter(
                        lease: lease
                    )
                )
            }
        }
    }

    func __leaseAll(callback: any AllLeaseCallback) async throws {
        // FIXME, actually use all connections
        // We currently only use this for schema updates
        return try await wrapExceptions {
            let sendableCallback = SendableAllLeaseCallback(callback)
            try await pool.withAllConnections { writer, readers in
                try sendableCallback.execute(
                    writeLease: KotlinLeaseAdapter(
                        lease: writer
                    ),
                    readLeases: readers.map { KotlinLeaseAdapter(lease: $0) }
                )
            }
        }
    }

    private func wrapExceptions<Result>(
        _ callback: () async throws -> Result
    ) async throws -> Result {
        do {
            return try await callback()
        } catch {
            try? PowerSyncKotlin.throwPowerSyncException(
                exception: PowerSyncException(
                    message: error.localizedDescription,
                    cause: nil
                )
            )
            // Won't reach here
            throw error
        }
    }
}

extension SQLiteConnectionPoolProtocol {
    func toKotlin() -> PowerSyncKotlin.SwiftSQLiteConnectionPool {
        return PowerSyncKotlin.SwiftSQLiteConnectionPool(
            adapter: SwiftSQLiteConnectionPoolAdapter(pool: self)
        )
    }
}
