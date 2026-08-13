import Foundation

/// Carries the tables changed by a write to the other processes sharing a database file.
///
/// Darwin notifications have no payload, so a receiver could only re-query everything. Instead
/// each write appends the tables it changed to a local table, and the notification just means
/// "there are new rows to read". Receivers skip rows written by their own ``author``, which is
/// what stops a process from waking itself, and only re-emit the tables that actually changed.
///
/// Held by the connection pool for shared (absolute path) databases; `nil` otherwise.
struct CrossProcessUpdateLog: Sendable {
    /// Identifies this pool's rows so it can ignore them when reading. Random per instance; a
    /// 64-bit space makes collisions negligible.
    let author: Int64
    let signal: CrossProcessChangeSignal
    let logger: any LoggerProtocol

    init(signal: CrossProcessChangeSignal, logger: any LoggerProtocol) {
        self.author = Int64.random(in: Int64.min ... Int64.max)
        self.signal = signal
        self.logger = logger
    }

    static let tableName = "ps_swift_updates"

    static let createTableSQL = """
        CREATE TABLE IF NOT EXISTS \(tableName) (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            author INTEGER NOT NULL,
            timestamp INTEGER NOT NULL,
            tables TEXT NOT NULL
        )
        """

    /// Rows older than this are pruned on each write. A receiver that falls behind by more than
    /// this window can no longer rely on the rows it missed still being there, so it emits a
    /// generic ``EXTERNAL_CHANGES_MARKER`` instead.
    static let retentionSeconds: Int64 = 15

    private static let insertSQL =
        "INSERT INTO \(tableName) (author, timestamp, tables) VALUES (?, unixepoch(), ?)"
    /// Scans the whole table, which is fine: this same prune is what keeps it down to the
    /// retention window, so it never grows enough to warrant an index.
    private static let pruneSQL =
        "DELETE FROM \(tableName) WHERE timestamp < unixepoch() - ?"

    static let readSQL =
        "SELECT id, tables FROM \(tableName) WHERE id > ? AND author != ? ORDER BY id"

    /// Reads a row of ``readSQL``: the row id, and the JSON array of tables it recorded.
    static func readRow(_ cursor: any SqlCursor) throws -> (id: Int64, tables: String) {
        (try cursor.getInt64(index: 0), try cursor.getString(index: 1))
    }

    /// Whether a changed table is worth telling other processes about.
    ///
    /// The `ps_` prefix is reserved for PowerSync internals, so anything without it is a user
    /// (or raw) table and always propagates. Of the internal ones only the user-data tables and
    /// `ps_crud` have a cross-process consumer: `watch` queries match the data tables and the
    /// upload client matches `ps_crud`. The rest is bookkeeping that wakes nobody, so recording
    /// and signalling it would be pure chatter during sync.
    static func isRelevant(_ table: String) -> Bool {
        guard table.hasPrefix("ps_") else { return true }
        return table.hasPrefix("ps_data__") || table.hasPrefix("ps_data_local__") || table == "ps_crud"
    }

    /// Appends the tables changed by a write, on the connection that just wrote them, and prunes
    /// stale rows. Returns whether a row was recorded, so the caller only signals other processes
    /// when there is something for them to read. Never throws: failing to record must not fail
    /// the write that already happened.
    func record(tables: Set<String>, lease: some SQLiteConnectionLease) -> Bool {
        let relevant = tables.filter(Self.isRelevant)
        guard !relevant.isEmpty else { return false }

        do {
            let json = String(decoding: try JSONEncoder().encode(relevant), as: UTF8.self)
            let _ = try lease.execute(
                sql: Self.insertSQL,
                parameters: [.int64(author), .string(json)]
            )
        } catch {
            logger.warning("Could not record cross-process update: \(error)", tag: "CrossProcessUpdateLog")
            return false
        }

        do {
            // Pruning is best effort: the row is already recorded, so a failure here must not
            // suppress the notification for it.
            let _ = try lease.execute(sql: Self.pruneSQL, parameters: [.int64(Self.retentionSeconds)])
        } catch {
            logger.debug("Could not prune cross-process update log: \(error)", tag: "CrossProcessUpdateLog")
        }
        return true
    }
}
