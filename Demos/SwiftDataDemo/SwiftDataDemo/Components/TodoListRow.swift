import SwiftUI

struct TodoListRow: View {
    let list: TodoList

    private var pendingCount: Int {
        // The to-many relationship is resolved through the inverse `list_id` column.
        list.todos.filter { !$0.completed }.count
    }

    var body: some View {
        HStack {
            Text(list.name)
            Spacer()
            if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}
