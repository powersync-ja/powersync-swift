import SwiftUI

struct TodoListRow: View {
  let todo: Todo
  let completeTapped: () -> Void

  var body: some View {
    HStack {
      Text(todo.description)
      Spacer()
      Button {
        completeTapped()
      } label: {
        Image(systemName: todo.isComplete ? "checkmark.circle.fill" : "circle")
      }
      .buttonStyle(.plain)
    }
  }
}


#Preview {
    TodoListRow(
      todo: .init(
        id: UUID().uuidString.lowercased(),
        listId: UUID().uuidString.lowercased(),
        photoId: nil,
        description: "description",
        isComplete: false,
        createdAt: "",
        completedAt: nil,
        createdBy: UUID().uuidString.lowercased(),
        completedBy: nil
      )
    ) {}
}
