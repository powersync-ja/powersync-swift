import Combine
import GRDB
import GRDBQuery
import PowerSync
import SwiftUI

struct ListsTodosRequest: ValueObservationQueryable {
    let list: ListWithTodoCounts

    static var defaultValue: [Todo] { [] }

    func fetch(_ database: Database) throws -> [Todo] {
        try Todo
            .filter(Todo.Columns.listId == list.id)
            .order(Todo.Columns.description)
            .order(Todo.Columns.isCompleted)
            .fetchAll(database)
    }
}

@Observable
class TodoViewModel {
    let grdb: DatabasePool
    let errorModel: ErrorViewModel

    init(
        grdb: DatabasePool,
        errorModel: ErrorViewModel
    ) {
        self.grdb = grdb
        self.errorModel = errorModel
    }

    func createTodo(name: String, listId: String) throws {
        try errorModel.withReporting("Could not create todo") {
            try grdb.write { database in
                try Todo(
                    id: UUID().uuidString,
                    description: name,
                    listId: listId,
                    isCompleted: false
                ).insert(database)
            }
        }
    }

    func toggleCompleted(todo: Todo) throws {
        try errorModel.withReporting("Could not update completed at") {
            var updatedTodo = todo
            try grdb.write { database in
                if todo.isCompleted {
                    updatedTodo.isCompleted = false
                    updatedTodo.completedAt = nil
                } else {
                    updatedTodo.completedAt = Date()
                    updatedTodo.isCompleted = true
                }
                _ = try updatedTodo.update(database)
            }
        }
    }

    func deleteTodo(_ id: String) throws {
        try errorModel.withReporting("Could not delete todo") {
            try grdb.write { database in
                _ = try Todo.deleteOne(
                    database,
                    key: id
                )
            }
        }
    }
}
