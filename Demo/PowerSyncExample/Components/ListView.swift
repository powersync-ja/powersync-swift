import SwiftUI
import IdentifiedCollections
import SwiftUINavigation
import PowerSync

struct ListView: View {
    @Environment(SystemManager.self) private var system

    @State private var lists: IdentifiedArrayOf<ListContent> = []
    @State private var error: Error?
    @State private var newList: NewListContent?
    @State private var editing: Bool = false
    @State private var status: SyncStatusData? = nil

    var body: some View {
        if status?.hasSynced != true {
            VStack {
                if let status = self.status {
                    if status.hasSynced != true {
                        Text("Busy with initial sync...")
                        
                        if let progress = status.downloadProgress {
                            ProgressView(value: progress.fraction)
                            
                            if progress.downloadedOperations == progress.totalOperations {
                                Text("Applying server-side changes...")
                            } else {
                                Text("Downloaded \(progress.downloadedOperations) out of \(progress.totalOperations)")
                            }
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

            IfLet($newList) { $newList in
                AddListView(newList: $newList) { result in
                    withAnimation {
                        self.newList = nil
                    }
                }
            }

            ForEach(lists) { list in
                NavigationLink(destination: TodosScreen(
                    listId: list.id
                )) {
                    ListRow(list: list)
                }
            }
            .onDelete { indexSet in
                Task {
                    await handleDelete(at: indexSet)
                }
            }
        }
        .animation(.default, value: lists)
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if (newList == nil) {
                    Button {
                        withAnimation {
                            newList = .init(
                                name: "",
                                ownerId: "",
                                createdAt: ""
                            )
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                } else {
                    Button("Cancel", role: .cancel) {
                        withAnimation {
                            newList = nil
                        }
                    }
                }
            }
        }
        .task {
            await system.watchLists { ls in
                withAnimation {
                    self.lists = IdentifiedArrayOf(uniqueElements: ls)
                }
            }
        }
        .task {
            self.status = system.db.currentStatus
            
            for await status in system.db.currentStatus.asFlow() {
                self.status = status
            }
        }
    }

    func handleDelete(at offset: IndexSet) async {
        do {
            error = nil
            let listsToDelete = offset.map { lists[$0] }

            try await system.deleteList(id: listsToDelete[0].id)

        } catch {
            self.error = error
        }
    }
}

#Preview {
    NavigationStack {
        ListView()
            .environment(SystemManager())
    }
}
