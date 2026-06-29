import Foundation
import SwiftData

/// A single todo item.
///
/// Stored in the PowerSync table `todo` with columns `descriptionText` (text),
/// `completed` (integer) and `list_id` (text, the to-one relationship's foreign key).
@Model
final class Todo {
    var id: String
    var descriptionText: String
    var completed: Bool
    var list: TodoList?

    init(
        id: String = UUID().uuidString.lowercased(),
        descriptionText: String,
        completed: Bool = false,
        list: TodoList? = nil
    ) {
        self.id = id
        self.descriptionText = descriptionText
        self.completed = completed
        self.list = list
    }
}
