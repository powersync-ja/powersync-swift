import GRDB
import GRDBQuery
import PowerSync
import PowerSyncGRDB
import SwiftUI

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

    do {
        var config = Configuration()
        config.configurePowerSync(
            schema: schema
        )
        let grdb = try DatabasePool(
            path: dbUrl.path,
            configuration: config
        )

        let powerSync = openPowerSyncWithGRDB(
            pool: grdb,
            schema: schema,
            identifier: "test.sqlite"
        )

        return Databases(
            grdb: grdb,
            powerSync: powerSync
        )
    } catch {
        fatalError("Could not open database: \(error)")
    }
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
