import GRDB
import GRDBQuery
import SwiftUI

struct TodosView: View {
    let list: ListWithTodoCounts

    @Environment(ViewModels.self) var viewModels

    @Query<ListsTodosRequest>
    var todos: [Todo]

    @State var showingAddSheet: Bool = false

    init(list: ListWithTodoCounts) {
        self.list = list
        _todos = Query(ListsTodosRequest(list: list))
    }

    var body: some View {
        StatusIndicatorView {
            ZStack {
                SwiftUI.List(todos) { todo in
                    TodoItemView(todo: todo)
                }
                // Floating Action Button
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            showingAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)
                                .padding()
                                .background(Circle().fill(Color.accentColor))
                                .shadow(radius: 4)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .padding()
                        .accessibilityLabel("Create New Todo")
                    }
                }
                // Modal overlay
                if showingAddSheet {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            showingAddSheet = false
                        }
                    AddTodoSheet(
                        isPresented: $showingAddSheet
                    ) { name in
                        try viewModels.todoViewModel.createTodo(
                            name: name,
                            listId: list.id
                        )
                    }
                }
            }

            .navigationTitle(list.name)
        }
    }
}
