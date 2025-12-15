import GRDB

/// Transaction observer used to track table updates made from GRDB mutations.
///
/// This class implements `TransactionObserver` and buffers table names that are
/// changed during a transaction. After the transaction commits, it notifies
/// listeners with the set of updated tables. Used by PowerSync to observe
/// changes made through GRDB APIs.
final class PowerSyncTransactionObserver: TransactionObserver {
    private var buffered: Set<String> = []

    let onChange: (_ tables: Set<String>) -> Void

    init(
        /// Called after a transaction has been committed, with the set of tables that changed
        onChange: @escaping (_ tables: Set<String>) -> Void
    ) {
        self.onChange = onChange
    }

    func observes(eventsOfKind _: DatabaseEventKind) -> Bool {
        // We want all the events for the PowerSync SDK
        return true
    }

    func databaseDidChange(with event: DatabaseEvent) {
        buffered.insert(event.tableName)
    }

    /// GRDB monitors statement execution in order to only
    /// fire this after the commit has been executed
    func databaseDidCommit(_: GRDB.Database) {
        // Notify about all buffered changes
        onChange(buffered)
        buffered.removeAll()
    }

    func databaseDidRollback(_: GRDB.Database) {
        // Discard buffered changes
        buffered.removeAll()
    }
}
