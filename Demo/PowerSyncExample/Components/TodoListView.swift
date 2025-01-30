import SwiftUI
import IdentifiedCollections
import SwiftUINavigation

struct TodoListView: View {
    @Environment(SystemManager.self) private var system
    let listId: String

    @State private var todos: IdentifiedArrayOf<Todo> = []
    @State private var error: Error?
    @State private var newTodo: NewTodo?
    @State private var editing: Bool = false

    var body: some View {
        List {
            if let error {
                ErrorText(error)
            }

            IfLet($newTodo) { $newTodo in
                AddTodoListView(newTodo: $newTodo, listId: listId) { result in
                    withAnimation {
                        self.newTodo = nil
                    }
                }
            }

            ForEach(todos) { todo in
                TodoListRow(todo: todo) {
                    Task {
                        await toggleCompletion(of: todo)
                    }
                }
            }
            .onDelete { indexSet in
                Task {
                    await delete(at: indexSet)
                }
            }
        }
        .animation(.default, value: todos)
        .navigationTitle("Todos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if (newTodo == nil) {
                    Button {
                        withAnimation {
                            newTodo = .init(
                                listId: listId,
                                isComplete: false,
                                description: ""
                            )
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                } else {
                    Button("Cancel", role: .cancel) {
                        withAnimation {
                            newTodo = nil
                        }
                    }
                }
            }
        }
        .task {
            await system.watchTodos(listId) { tds in
                withAnimation {
                    self.todos = IdentifiedArrayOf(uniqueElements: tds)
                }
            }
        }
    }

    func toggleCompletion(of todo: Todo) async {
        var updatedTodo = todo
        updatedTodo.isComplete.toggle()
        do {
            error = nil
            try await system.updateTodo(updatedTodo)
        } catch {
            self.error = error
        }
    }

    func delete(at offset: IndexSet) async {
        do {
            error = nil
            let todosToDelete = offset.map { todos[$0] }

            try await system.deleteTodo(id: todosToDelete[0].id)

        } catch {
            self.error = error
        }
    }
}

#Preview {
    NavigationStack {
        TodoListView(
            listId: UUID().uuidString.lowercased()
        ).environment(SystemManager())
    }
}
