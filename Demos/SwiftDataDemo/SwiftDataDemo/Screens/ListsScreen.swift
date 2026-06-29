import PowerSync
import SwiftData
import SwiftUI

/// All todo lists, fetched with a plain `@Query`. The query goes through the
/// `PowerSyncDataStore`; reactivity to sync downloads is provided by the
/// `PowerSyncChangeObserver` started in `SystemManager.start()`.
///
/// Like PowerSyncExample's list view, the UI is gated on the first sync: until
/// `SyncStatusData.hasSynced` the screen shows download progress instead of an
/// empty state.
struct ListsScreen: View {
    @Environment(SystemManager.self) private var system
    @Environment(NavigationModel.self) private var navigationModel
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \TodoList.name) private var lists: [TodoList]

    @State private var showAddList = false
    @State private var newListName = ""
    @State private var error: Error?
    @State private var status: SyncStatusData?

    var body: some View {
        if status?.hasSynced != true {
            VStack {
                if let status {
                    Text("Busy with initial sync...")

                    if let progress = status.downloadProgress {
                        ProgressView(value: progress.fraction)

                        if progress.downloadedOperations == progress.totalOperations {
                            Text("Applying server-side changes...")
                        } else {
                            Text("Downloaded \(progress.downloadedOperations) out of \(progress.totalOperations)")
                        }
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                }
            }
        }

        List {
            if let error {
                ErrorText(error)
            }

            ForEach(lists) { list in
                Button {
                    navigationModel.path.append(Route.todos(listId: list.id, listName: list.name))
                } label: {
                    TodoListRow(list: list)
                }
                .foregroundStyle(.primary)
            }
            .onDelete(perform: deleteLists)
        }
        .overlay {
            if lists.isEmpty, status?.hasSynced == true {
                ContentUnavailableView(
                    "No lists yet",
                    systemImage: "checklist",
                    description: Text("Tap + to create your first list.")
                )
            }
        }
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Sign out") {
                    Task {
                        try? await system.signOut()
                        navigationModel.path = NavigationPath()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddList = true
                } label: {
                    Label("Add list", systemImage: "plus")
                }
            }
        }
        .alert("Add list", isPresented: $showAddList) {
            TextField("Name", text: $newListName)
            Button("Add") {
                addList()
            }
            Button("Cancel", role: .cancel) {
                newListName = ""
            }
        }
        .task {
            await system.start()
        }
        .task {
            status = system.db.currentStatus
            for await current in system.db.currentStatus.asFlow() {
                status = current
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    private func addList() {
        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        newListName = ""
        guard !name.isEmpty else { return }
        do {
            error = nil
            modelContext.insert(TodoList(name: name))
            try modelContext.save()
        } catch {
            self.error = error
        }
    }

    private func deleteLists(at offsets: IndexSet) {
        // The cascade delete rule removes the list's todos as well.
        do {
            error = nil
            for index in offsets {
                modelContext.delete(lists[index])
            }
            try modelContext.save()
        } catch {
            self.error = error
        }
    }
}
