import SwiftData
import SwiftUI

/// The todos of a single list, fetched with a `@Query` filtered on the to-one
/// relationship's id and sorted by description.
struct TodosScreen: View {
    let listId: String
    let listName: String

    @Environment(\.modelContext) private var modelContext

    @Query private var todos: [Todo]

    @State private var showAddTodo = false
    @State private var newTodoDescription = ""
    @State private var error: Error?

    init(listId: String, listName: String) {
        self.listId = listId
        self.listName = listName
        _todos = Query(
            filter: #Predicate<Todo> { $0.list?.id == listId },
            sort: \Todo.descriptionText
        )
    }

    var body: some View {
        List {
            if let error {
                ErrorText(error)
            }

            ForEach(todos) { todo in
                TodoRow(todo: todo) {
                    toggle(todo)
                }
            }
            .onDelete(perform: deleteTodos)
        }
        .overlay {
            if todos.isEmpty {
                ContentUnavailableView(
                    "No todos yet",
                    systemImage: "checkmark.circle",
                    description: Text("Tap + to add a todo to this list.")
                )
            }
        }
        .navigationTitle(listName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddTodo = true
                } label: {
                    Label("Add todo", systemImage: "plus")
                }
            }
        }
        .alert("Add todo", isPresented: $showAddTodo) {
            TextField("Description", text: $newTodoDescription)
            Button("Add") {
                addTodo()
            }
            Button("Cancel", role: .cancel) {
                newTodoDescription = ""
            }
        }
    }

    private func addTodo() {
        let descriptionText = newTodoDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        newTodoDescription = ""
        guard !descriptionText.isEmpty else { return }
        do {
            error = nil
            // Fetch the list in this context to set the to-one relationship.
            let descriptor = FetchDescriptor<TodoList>(
                predicate: #Predicate { $0.id == listId }
            )
            guard let list = try modelContext.fetch(descriptor).first else { return }
            modelContext.insert(Todo(descriptionText: descriptionText, list: list))
            try modelContext.save()
        } catch {
            self.error = error
        }
    }

    private func toggle(_ todo: Todo) {
        do {
            error = nil
            todo.completed.toggle()
            try modelContext.save()
        } catch {
            self.error = error
        }
    }

    private func deleteTodos(at offsets: IndexSet) {
        do {
            error = nil
            for index in offsets {
                modelContext.delete(todos[index])
            }
            try modelContext.save()
        } catch {
            self.error = error
        }
    }
}
