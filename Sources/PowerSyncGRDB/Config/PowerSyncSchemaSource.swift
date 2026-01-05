import GRDB
import PowerSync

/// A schema source used by GRDB to resolve primary keys for PowerSync views.
///
/// This struct allows GRDB to identify the primary key columns for tables/views
/// defined in the PowerSync schema, enabling correct integration with GRDB's
/// database observation and record management features.
struct PowerSyncSchemaSource: DatabaseSchemaSource {
    let schema: Schema

    func columnsForPrimaryKey(_: Database, inView view: DatabaseObjectID) throws -> [String]? {
        if schema.tables.first(where: { table in
            table.viewName == view.name
        }) != nil {
            return ["id"]
        }
        return nil
    }
}
