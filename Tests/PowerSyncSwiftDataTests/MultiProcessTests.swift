import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Writes from another process (an App Intent or interactive widget) must reach the app
/// live. Two database instances over the same file use independent pools — the same
/// blindness two processes exhibit — so this pins the whole chain: SwiftData write on the
/// "extension" side → ps_crud capture → cross-process signal → app-side observer
/// reconciliation → `ModelContext.didSave` (the signal `@Query` refreshes on).
@Suite("Multi-process SwiftData")
struct MultiProcessTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test(.timeLimit(.minutes(1)))
    func extensionWritesReachTheAppLive() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiprocess-\(UUID().uuidString)/shared.db").path

        // App side: container + live observer.
        let appDatabase = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [Note.self]),
            dbFilename: path,
            logger: DefaultLogger(minSeverity: .warning)
        )
        let appConfiguration = PowerSyncDataStoreConfiguration(name: "mp-app", database: appDatabase)
        let appContainer = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [appConfiguration]
        )
        let observer = PowerSyncChangeObserver(container: appContainer, configuration: appConfiguration)
        try await observer.start(observing: [Note.self])

        let observation = Task {
            for await notification in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                let inserted = notification.userInfo?["inserted"] as? [PersistentIdentifier] ?? []
                if !inserted.isEmpty {
                    return true
                }
            }
            return false
        }

        // "Extension" side: its own database instance over the same file, default
        // configuration (writes allowed), one ModelContext save.
        let extensionDatabase = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [Note.self]),
            dbFilename: path,
            logger: DefaultLogger(minSeverity: .warning)
        )
        let extensionContainer = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "mp-extension", database: extensionDatabase)]
        )
        let extensionContext = ModelContext(extensionContainer)
        extensionContext.insert(Note(id: "from-intent", title: "escrita fuera", done: false, count: 1))
        try extensionContext.save()

        // The write is captured for upload (shared queue at the file level).
        let batch = try await extensionDatabase.getCrudBatch()
        #expect(batch?.crud.isEmpty == false)

        // The app side must observe the change live (observer didSave, the signal @Query
        // refreshes on), not just on re-fetch.
        let sawInsert = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await observation.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(sawInsert)

        let fetched = try ModelContext(appContainer).fetch(FetchDescriptor<Note>())
        #expect(fetched.first?.title == "escrita fuera")

        await observer.stop()
        observation.cancel()
        try await appDatabase.close()
        try await extensionDatabase.close(deleteDatabase: true)
    }
}
