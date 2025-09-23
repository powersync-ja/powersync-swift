import GRDB
import GRDBQuery
import PowerSync
import PowerSyncGRDB
import SwiftUI

@Observable
class Databases {
    let grdb: DatabasePool
    let powerSync: PowerSyncDatabaseProtocol

    init(grdb: DatabasePool, powerSync: PowerSyncDatabaseProtocol) {
        self.grdb = grdb
        self.powerSync = powerSync
    }
}

func openDatabase()
    -> Databases
{
    let schema = Schema(
        tables: [
            listsTable,
            todosTable
        ])

    let dbUrl = FileManager
        .default
        .urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("test.sqlite")

    var config = Configuration()
    config.configurePowerSync(
        schema: schema
    )

    guard let grdb = try? DatabasePool(
        path: dbUrl.path,
        configuration: config
    ) else {
        fatalError("Could not open database")
    }

    let powerSync = OpenedPowerSyncDatabase(
        schema: schema,
        pool: GRDBConnectionPool(
            pool: grdb
        ),
        identifier: "test"
    )

    return Databases(
        grdb: grdb,
        powerSync: powerSync
    )
}

@main
struct GRDB_DemoApp: App {
    let viewModels: ViewModels

    init() {
        viewModels = ViewModels(
            databases: openDatabase()
        )
    }

    var body: some Scene {
        WindowGroup {
            ErrorAlertView {
                RootScreen(
                    supabaseViewModel: viewModels.supabaseViewModel
                )
            }
            .environment(viewModels)
            // Used by GRDB observed queries
            .databaseContext(.readWrite { viewModels.databases.grdb })
        }
    }
}
