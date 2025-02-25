import SwiftUI
import IdentifiedCollections
import SwiftUINavigation

struct ListView: View {
    @Environment(SystemManager.self) private var system

    @State private var lists: IdentifiedArrayOf<ListContent> = []
    @State private var error: Error?
    @State private var newList: NewListContent?
    @State private var editing: Bool = false
    @State private var didSync: Bool = false

    var body: some View {
        if !didSync {
            Text("Busy with sync!").task {
                do {
                    try await system.db.waitForFirstSync(priority: 1)
                    didSync = true;
                } catch {}
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
