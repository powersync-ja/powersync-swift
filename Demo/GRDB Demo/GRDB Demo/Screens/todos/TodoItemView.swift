import GRDB
import GRDBQuery
import SwiftUI

struct TodoItemView: View {
    var todo: Todo

    @Environment(ViewModels.self) var viewModels

    static let completedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm yyyy/MM/dd"
        return formatter
    }()

    var body: some View {
        VStack {
            HStack {
                Text(todo.description).font(.title)
                Spacer()
                Button {
                    try? viewModels.todoViewModel.toggleCompleted(todo: todo)
                } label: {
                    if todo.isCompleted {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    } else {
                        // make the icon empty circle when not completed
                        Image(systemName: "circle").foregroundColor(.green)
                    }
                }
            }
            HStack {
                if let completedAt = todo.completedAt {
                    Text("Completed at \(Self.completedAtFormatter.string(from: completedAt))")
                }
                Spacer()
            }
        }
        .padding()
    }
}
