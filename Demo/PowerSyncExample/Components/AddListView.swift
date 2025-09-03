import SwiftUI

struct AddListView: View {
    @Environment(SystemManager.self) private var system
    
    @Binding var newList: NewListContent
    let completion: (Result<Bool, Error>) -> Void

    var body: some View {
        Section {
            TextField("Name", text: $newList.name)
            Button("Save") {
                Task {
                    do {
                        try await system.insertList(newList)
                        completion(.success(true))
                    } catch {
                        completion(.failure(error))
                        throw error
                    }
                }
            }
        }
    }
}

#Preview {
    AddListView(
        newList: .constant(
            .init(
                name: "",
                ownerId: "",
                createdAt: ""
            )
        )
    ) { _ in
    }.environment(SystemManager())
}
