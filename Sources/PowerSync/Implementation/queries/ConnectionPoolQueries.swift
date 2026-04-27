import AsyncAlgorithms

/// Implements ``Queries`` by delegating to a ``SQLiteConnectionPoolProtocol``.
struct ConnectionPoolQueries: Sendable, Queries {
    let pool: SQLiteConnectionPoolProtocol

    func writeLock<R: Sendable>(callback: @escaping @Sendable (any ConnectionContext) throws -> R) async throws -> R {
        try await pool.write { connection in
            try callback(ConnectionLeaseContext(lease: connection))
        }
    }
    
    func readLock<R: Sendable>(callback: @escaping @Sendable (any ConnectionContext) throws -> R) async throws -> R {
        try await pool.read { connection in
            try callback(ConnectionLeaseContext(lease: connection))
        }
    }
    
    func withAll<R: Sendable>(callback: @escaping @Sendable (_ writer: any ConnectionContext, _ readers: [any ConnectionContext]) throws -> R) async throws -> R {
        try await pool.withAllConnections { writer, readers in
            let writer = ConnectionLeaseContext(lease: writer)
            let readers = readers.map { ConnectionLeaseContext(lease: $0) }

            return try callback(writer, readers)
        }
    }

    func watch<RowType: Sendable>(options: WatchOptions<RowType>) throws -> AsyncThrowingStream<[RowType], any Error> {
        AsyncThrowingStream { continuation in
            // Create an outer task to monitor cancellation
            let task = Task {
                do {
                    let watchedTables = try await self.getQuerySourceTables(
                        sql: options.sql,
                        parameters: options.parameters
                    )

                    let updateNotifications = pool.tableUpdates.filter { changedTables in
                        changedTables.contains(where: watchedTables.contains)
                    }.map { _ in () }
                    // Allows emitting the first result even if there aren't changes
                    let withInitial = AsyncAlgorithms.merge([()].async, updateNotifications)
                    let merged = MergeItemSequence(inner: withInitial)

                    for try await _ in merged {
                        // Check if the outer task is cancelled
                        try Task.checkCancellation()

                        try continuation.yield(await self.getAll(
                            sql: options.sql,
                            parameters: options.parameters,
                            mapper: options.mapper
                        ))
                        try await sleepForSeconds(seconds: options.throttle)
                    }

                    continuation.finish()
                } catch {
                    if error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            // Propagate cancellation from the outer task to the inner task
            continuation.onTermination = { @Sendable _ in
                task.cancel() // This cancels the inner task when the stream is terminated
            }
        }
    }

    private func getQuerySourceTables(
        sql: String,
        parameters: [Sendable?]
    ) async throws -> Set<String> {
        let rows = try await getAll(
            sql: "EXPLAIN \(sql)",
            parameters: parameters,
            mapper: { cursor in
                try ExplainQueryResult(
                    addr: cursor.getString(index: 0),
                    opcode: cursor.getString(index: 1),
                    p1: cursor.getInt64(index: 2),
                    p2: cursor.getInt64(index: 3),
                    p3: cursor.getInt64(index: 4)
                )
            }
        )

        let rootPages = rows.compactMap { row in
            if (row.opcode == "OpenRead" || row.opcode == "OpenWrite") &&
                row.p3 == 0 && row.p2 != 0
            {
                return row.p2
            }
            return nil
        }

        do {
            let pagesData = try StreamingSyncClient.jsonEncoder.encode(rootPages)
            guard let pagesString = String(data: pagesData, encoding: .utf8) else {
                throw PowerSyncError.operationFailed(
                    message: "Failed to convert pages data to UTF-8 string"
                )
            }

            let tableRows = try await getAll(
                sql: "SELECT tbl_name FROM sqlite_master WHERE rootpage IN (SELECT json_each.value FROM json_each(?))",
                parameters: [
                    pagesString,
                ]
            ) { try $0.getString(index: 0) }

            return Set(tableRows)
        } catch {
            throw PowerSyncError.operationFailed(
                message: "Could not determine watched query tables",
                underlyingError: error
            )
        }
    }
}

private struct ExplainQueryResult {
    let addr: String
    let opcode: String
    let p1: Int64
    let p2: Int64
    let p3: Int64
}
