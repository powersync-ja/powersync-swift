import SwiftUI

struct TodoRow: View {
    let todo: Todo
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.completed ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Text(todo.descriptionText)
                .strikethrough(todo.completed)
                .foregroundStyle(todo.completed ? .secondary : .primary)
        }
    }
}
