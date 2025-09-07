import PowerSyncKotlin

final class SwiftSQLiteConnectionPoolAdapter: PowerSyncKotlin.SwiftPoolAdapter {
    let pool: SQLiteConnectionPoolProtocol

    init(
        pool: SQLiteConnectionPoolProtocol
    ) {
        self.pool = pool
    }

    func __closePool() async throws {
        do {
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

    func __leaseRead(callback: @escaping (Any) -> Void) async throws {
        do {
            try await pool.read { pointer in
                callback(pointer)
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

    func __leaseWrite(callback: @escaping (Any) -> Void) async throws {
        do {
            try await pool.write { pointer in
                callback(pointer)
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
