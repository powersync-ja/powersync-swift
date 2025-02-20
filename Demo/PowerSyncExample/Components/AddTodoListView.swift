import Foundation
import SwiftUI

struct AddTodoListView: View {
    @Environment(SystemManager.self) private var system
    @State private var isLoading = false
    
    @Binding var newTodo: NewTodo
    let listId: String
    let completion: (Result<Bool, Error>) -> Void
    
    var body: some View {
        Section {
            TextField("Description", text: $newTodo.description)
            
            Button {
                Task {
                    isLoading = true
                    defer { isLoading = false }
                    
                    do {
                        try await system.insertTodo(newTodo, listId)
                        completion(.success(true))
                    } catch {
                        completion(.failure(error))
                        throw error
                    }
                }
            } label: {
                HStack {
                    Text("Save")
                    if isLoading {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isLoading)
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
