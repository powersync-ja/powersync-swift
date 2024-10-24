import Foundation
import SwiftUI

struct TodosScreen: View {
    let listId: String
    
    var body: some View {
        TodoListView(
            listId: listId
        )
    }
}

#Preview {
    NavigationStack {
        TodosScreen(
            listId: UUID().uuidString.lowercased()
        )
    }
}
