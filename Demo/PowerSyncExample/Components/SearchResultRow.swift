//
//  SearchResultRow.swift
//  PowerSyncExample
//
//  Created by Wade Morris on 4/9/25.
//

import SwiftUI

struct SearchResultRow: View {
    let item: SearchResultItem

    var body: some View {
        HStack {
            
            Image(systemName: item.type == .list ? "list.bullet" : "checkmark.circle")
                .foregroundColor(.secondary)

            if let list = item.listContent {
                Text(list.name)
            } else if let todo = item.todo {
                Text(todo.description)
                    .strikethrough(todo.isComplete, color: .secondary)
                    .foregroundColor(todo.isComplete ? .secondary : .primary)
            } else {
                Text("Unknown item")
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
        SearchResultRow(item: SearchResultItem(
            id: UUID().uuidString,
            type: .list,
            content: ListContent(id: UUID().uuidString, name: "Groceries", createdAt: "now", ownerId: "user1")
        ))
        SearchResultRow(item: SearchResultItem(
            id: UUID().uuidString,
            type: .todo,
            content: Todo(id: UUID().uuidString, listId: "list1", description: "Buy milk", isComplete: false)
        ))
        SearchResultRow(item: SearchResultItem(
            id: UUID().uuidString,
            type: .todo,
            content: Todo(id: UUID().uuidString, listId: "list1", description: "Walk the dog", isComplete: true)
        ))
    }
}
