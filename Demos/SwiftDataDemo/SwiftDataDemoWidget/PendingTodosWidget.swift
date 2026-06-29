import SwiftUI
import WidgetKit

/// Widget showing the first pending todos synced by PowerSync. Each row has an
/// interactive button that completes the todo by WRITING from the widget's process
/// through the shared PowerSync database (see `CompleteTodoIntent`).
struct PendingTodosWidget: Widget {
    let kind = "PendingTodosWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PendingTodosProvider()) { entry in
            PendingTodosView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Pending Todos")
        .description("Shows your pending todos, synced by PowerSync.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PendingTodosView: View {
    let entry: PendingTodosEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pending")
                    .font(.headline)
                Spacer()
                Text("\(entry.pendingCount)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if entry.todos.isEmpty {
                Spacer()
                Text("All done!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(entry.todos) { todo in
                    HStack(spacing: 4) {
                        Button(intent: CompleteTodoIntent(todoId: todo.id)) {
                            Image(systemName: "circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        Text(todo.descriptionText)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
