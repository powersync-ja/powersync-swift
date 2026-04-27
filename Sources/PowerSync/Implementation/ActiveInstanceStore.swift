final class DatabaseGroupCollection: Sendable {
    private let groups: Mutex<[ActiveDatabaseGroupData]> = Mutex([])

    fileprivate func closeGroup(identifier: String) {
        groups.withLock { $0.removeAll { group in group.identifier == identifier } }
    }

    func referenceGroup(identifier: String, logger: LoggerProtocol) -> ActiveDatabaseGroup {
        groups.withLock { activeDatabases in
            let existingGroup = activeDatabases.first { $0.identifier == identifier }
            let data: ActiveDatabaseGroupData
            if let existingGroup {
                logger.warning("""
Multiple PowerSync instances for the same database have been detected.
This can cause unexpected results.
Please check your PowerSync client instantiation logic if this is not intentional.
""", tag: "DatabaseGroupCollection")
                data = existingGroup
            } else {
                data = ActiveDatabaseGroupData(identifier: identifier)
                activeDatabases.append(data)
            }

            return ActiveDatabaseGroup(data: data, collection: self)
        }
    }
    
    static let shared = DatabaseGroupCollection()
}

private final class ActiveDatabaseGroupData: Sendable {
    let identifier: String
    let syncCoordinator = SyncCoordinator()

    init(identifier: String) {
        self.identifier = identifier
    }
}

/// A collection  of PowerSync databases with the same path / identifier.
///
/// We expect that each group will only ever have one database because we encourage users to write their databases as
/// singletons. We print a warning when two databasees are part of the same group.
/// Additionally, we want to avoid two databases in the same group having a sync stream open at the same time to avoid
/// duplicate resources being used. For this reason, each active database group has a single sync coordinator actor
/// responsible for initializing the sync process for all databases in the group.
final class ActiveDatabaseGroup: Sendable {
    fileprivate let data: ActiveDatabaseGroupData
    private weak let collection: DatabaseGroupCollection?

    fileprivate init(data: ActiveDatabaseGroupData, collection: DatabaseGroupCollection) {
        self.data = data
        self.collection = collection
    }

    var syncCoordinator: SyncCoordinator {
        data.syncCoordinator
    }

    deinit {
        if let collection {
            collection.closeGroup(identifier: self.data.identifier)
        }
    }
}
