import Foundation
import SwiftData

/// A list of todos.
///
/// Stored in the PowerSync table `todo_list` (the snake_case form of the entity name,
/// derived by `PowerSyncSchema(for:)`). The `todos` relationship is resolved through the
/// inverse `list_id` column on the `todo` table; no extra column exists on this table.
@Model
final class TodoList {
    var id: String
    var name: String

    @Relationship(deleteRule: .cascade, inverse: \Todo.list)
    var todos: [Todo] = []

    init(id: String = UUID().uuidString.lowercased(), name: String) {
        self.id = id
        self.name = name
    }
}
