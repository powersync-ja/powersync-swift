import SwiftUI

struct AddListView: View {
    @Environment(PowerSyncManager.self) private var powerSync
    
    @Binding var newList: NewListContent
    let completion: (Result<Bool, Error>) -> Void

    var body: some View {
        Section {
            TextField("Name", text: $newList.name)
            Button("Save") {
                Task.detached {
                    do {
                        try await powerSync.insertList(newList)
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
    }.environment(PowerSyncManager())
}
