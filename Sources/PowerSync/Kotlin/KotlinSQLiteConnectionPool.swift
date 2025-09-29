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
        updateTrackingTask = Task {
            do {
                for try await updates in pool.tableUpdates {
                    _ = try await callback.invoke(p1: updates)
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
            try await pool.read { lease in
                try callback.execute(
                    lease: KotlinLeaseAdapter(
                        lease: lease
                    )
                )
            }
        }
    }

    func __leaseWrite(callback: any LeaseCallback) async throws {
        return try await wrapExceptions {
            try await pool.write { lease in
                try callback.execute(
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
            try await pool.write { lease in
                try callback.execute(
                    writeLease: KotlinLeaseAdapter(
                        lease: lease
                    ),
                    readLeases: []
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
