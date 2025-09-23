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

    func linkUpdates(callback: any KotlinSuspendFunction1) {
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

    func __closePool() async throws {
        do {
            updateTrackingTask?.cancel()
            updateTrackingTask = nil
            try pool.close()
        } catch {
            try? PowerSyncKotlin.throwPowerSyncException(
                exception: PowerSyncException(
                    message: error.localizedDescription,
                    cause: nil
                )
            )
        }
    }

    func __leaseRead(callback: any LeaseCallback) async throws {
        do {
            var errorToThrow: Error?
            try await pool.read { lease in
                do {
                    try callback.execute(
                        lease: KotlinLeaseAdapter(
                            lease: lease
                        )
                    )
                } catch {
                    errorToThrow = error
                }
            }
            if let errorToThrow {
                throw errorToThrow
            }
        } catch {
            try? PowerSyncKotlin.throwPowerSyncException(
                exception: PowerSyncException(
                    message: error.localizedDescription,
                    cause: nil
                )
            )
        }
    }

    func __leaseWrite(callback: any LeaseCallback) async throws {
        do {
            var errorToThrow: Error?
            try await pool.write { lease in
                do {
                    try callback.execute(
                        lease: KotlinLeaseAdapter(
                            lease: lease
                        )
                    )
                } catch {
                    errorToThrow = error
                }
            }
            if let errorToThrow {
                throw errorToThrow
            }
        } catch {
            try? PowerSyncKotlin.throwPowerSyncException(
                exception: PowerSyncException(
                    message: error.localizedDescription,
                    cause: nil
                )
            )
        }
    }

    func __leaseAll(callback: any AllLeaseCallback) async throws {
        // TODO, actually use all connections
        do {
            try await pool.write { lease in
                try? callback.execute(
                    writeLease: KotlinLeaseAdapter(
                        lease: lease
                    ),
                    readLeases: []
                )
            }
        } catch {
            try? PowerSyncKotlin.throwPowerSyncException(
                exception: PowerSyncException(
                    message: error.localizedDescription,
                    cause: nil
                )
            )
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
