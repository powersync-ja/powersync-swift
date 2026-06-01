import GRDB

class AllWritesObserver: TransactionObserver {
    private(set) var committedTables: Set<String> = []
    private var uncomittedTables: Set<String> = []

    var databaseEventObservationStrategy: DatabaseEventObservationStrategy {
        var strategy = DatabaseEventObservationStrategy.default
        // Don't filter on database event kind, so that we are
        // notified of changes performed through the SQLite C API:
        strategy.requiresDatabaseEventKind = false
        return strategy
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        // This will never be called since requiresDatabaseEventKind is false
        true
    }

    func databaseDidChange(with event: DatabaseEvent) {
        uncomittedTables.insert(event.tableName)
    }

    func databaseDidCommit(_ db: GRDB.Database) {
        committedTables.formUnion(uncomittedTables)
        uncomittedTables.removeAll()
    }

    func databaseDidRollback(_ db: GRDB.Database) {
        uncomittedTables.removeAll()
    }
}
