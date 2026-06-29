import Foundation
import PowerSync
import PowerSyncSwiftData
import SwiftData

private let logTag = "SystemManager"

/// Bootstraps the PowerSync-backed SwiftData stack:
///
/// 1. Opens the `PowerSyncDatabase` over the shared App Group file (the widget reads the
///    same file).
/// 2. Builds a `ModelContainer` whose only store is a `PowerSyncDataStore`, so every
///    `@Query` / `ModelContext` operation goes through PowerSync.
/// 3. Starts a `PowerSyncChangeObserver` so rows downloaded by sync are re-injected into
///    SwiftData and `@Query` views update live.
/// 4. Connects PowerSync to the backend through the Supabase connector.
///
/// We use the MainActor SupabaseConnector synchronously here, this requires specifying
/// that SystemManager runs on the MainActor. We don't actually block the MainActor with
/// anything.
@Observable
@MainActor
final class SystemManager {
    let connector = SupabaseConnector()
    let db: any PowerSyncDatabaseProtocol
    let container: ModelContainer

    @ObservationIgnored
    private let observer: PowerSyncChangeObserver
    @ObservationIgnored
    private var observing = false

    init() {
        do {
            let database = try SharedDatabase.openDatabase()
            let configuration = PowerSyncDataStoreConfiguration(
                name: "powersync",
                database: database
            )
            let container = try ModelContainer(
                for: SwiftData.Schema(SharedDatabase.models),
                configurations: [configuration]
            )
            db = database
            self.container = container
            observer = PowerSyncChangeObserver(
                container: container,
                configuration: configuration
            )
        } catch {
            fatalError("Failed to bootstrap the PowerSync SwiftData stack: \(error)")
        }
    }

    /// Starts the change observer (once) and connects to the PowerSync service.
    func start() async {
        do {
            if !observing {
                try await observer.start(observing: SharedDatabase.models)
                observing = true
            }
            if db.currentStatus.connected == false {
                try await db.connect(connector: connector)
            }
        } catch {
            db.logger.error("Failed to start sync: \(error)", tag: logTag)
        }
    }

    /// Disconnects, clears the local database and signs out of Supabase. The change
    /// observer notices the cleared tables and removes the models from SwiftData.
    func signOut() async throws {
        try await db.disconnectAndClear()
        try await connector.client.auth.signOut()
    }
}
