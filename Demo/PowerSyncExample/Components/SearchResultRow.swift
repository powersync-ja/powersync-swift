import SwiftUI

struct SearchResultRow: View {
    let item: SearchResultItem

    var body: some View {
        HStack {

            Image(
                systemName: {
                    switch item.content {
                    case .list:
                        return "list.bullet"
                    case .todo:
                        return "checkmark.circle"
                    }
                }()
            )
            .foregroundColor(.secondary)
            
            switch item.content {
            case .list(let listContent):
                Text(listContent.name)

            case .todo(let todo):
                Text(todo.description)
                    .strikethrough(todo.isComplete, color: .secondary)
                    .foregroundColor(todo.isComplete ? .secondary : .primary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    List {
        SearchResultRow(
            item: SearchResultItem(
                id: UUID().uuidString,
                content: .list(
                    ListContent(
                        id: UUID().uuidString,
                        name: "Groceries",
                        createdAt: "now",
                        ownerId: "user1"
                    )
                )
            )
        )
        SearchResultRow(
            item: SearchResultItem(
                id: UUID().uuidString,
                content: .todo(
                    Todo(
                        id: UUID().uuidString,
                        listId: "list1",
                        description: "Buy milk",
                        isComplete: false
                    )
                )
            )
        )
        SearchResultRow(
            item: SearchResultItem(
                id: UUID().uuidString,
                content: .todo(
                    Todo(
                        id: UUID().uuidString,
                        listId: "list1",
                        description: "Walk the dog",
                        isComplete: true
                    )
                )
            )
        )
    }
}
