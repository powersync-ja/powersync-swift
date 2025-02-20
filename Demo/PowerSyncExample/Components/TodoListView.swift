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
    @State private var isLoadingTodos: Bool = false
    @State private var batchInsertProgress: Double? = nil

    var body: some View {
        ZStack {
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

                if let progress = batchInsertProgress {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Inserting todos...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            ProgressView(value: progress)
                                .progressViewStyle(LinearProgressViewStyle())

                            Text("\(Int(progress * 100))% complete")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                ForEach(todos) { todo in
                    TodoListRow(todo: todo) {
                        Task {
                            try await toggleCompletion(of: todo)
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
            .animation(.default, value: batchInsertProgress)
            .navigationTitle("Todos")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if batchInsertProgress != nil {
                        // Show nothing while batch inserting
                        EmptyView()
                    } else if (newTodo == nil) {
                        Menu {
                            Button {
                                withAnimation {
                                    newTodo = .init(
                                        listId: listId,
                                        isComplete: false,
                                        description: ""
                                    )
                                }
                            } label: {
                                Label("Add Single Todo", systemImage: "plus")
                            }

                            Button {
                                Task {
                                    withAnimation {
                                        batchInsertProgress = 0
                                    }

                                    do {
                                        try await system.insertManyTodos(listId: listId) { progress in
                                            withAnimation {
                                                batchInsertProgress = progress
                                                if progress >= 1.0 {
                                                    // Small delay to show 100% before hiding
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                                        withAnimation {
                                                            batchInsertProgress = nil
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    } catch {
                                        self.error = error
                                        withAnimation {
                                            batchInsertProgress = nil
                                        }
                                    }
                                }
                            } label: {
                                Label("Add Many Todos", systemImage: "plus.square.on.square")
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

            if isLoadingTodos && todos.isEmpty {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.05))
            }
        }
        .task {
            isLoadingTodos = true
            await system.watchTodos(listId) { tds in
                withAnimation {
                    self.todos = IdentifiedArrayOf(uniqueElements: tds)
                    self.isLoadingTodos = false
                }
            }
        }
    }

    func toggleCompletion(of todo: Todo) async throws {
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
