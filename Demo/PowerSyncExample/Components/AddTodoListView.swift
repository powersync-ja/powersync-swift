import Foundation
import SwiftUI

struct AddTodoListView: View {
    @Environment(SystemManager.self) private var system
    
    @Binding var newTodo: NewTodo
    let listId: String
    let completion: (Result<Bool, Error>) -> Void

    var body: some View {
        Section {
            TextField("Description", text: $newTodo.description)
            Button("Save") {
                Task{
                    do {
                        try await system.insertTodo(newTodo, listId)
                        await completion(.success(true))
                    } catch {
                        await completion(.failure(error))
                        throw error
                    }
                }
            }
        }
    }
}

#Preview {
    AddTodoListView(
        newTodo: .constant(
            .init(
                listId: UUID().uuidString.lowercased(),
                isComplete: false,
                description: ""
            )
        ),
        listId: UUID().uuidString.lowercased()
    ){ _ in
    }.environment(SystemManager())
}
