import Auth
import Combine
import GRDB
import GRDBQuery
import PowerSync
import SwiftUI

struct ListsWithTodoCountsRequest: ValueObservationQueryable {
    static var defaultValue: [ListWithTodoCounts] { [] }

    func fetch(_ database: Database) throws -> [ListWithTodoCounts] {
        // Association for completed todos
        let pendingTodos = List.todos.filter(Todo.Columns.isCompleted == false)

        // It's tricky to annotate with opposing checks for isCompleted at once
        // So we just check the pending todos count
        let request = List
            .annotated(with: [
                pendingTodos.count.forKey("pendingCount")
            ]).order(sql: "pendingCount DESC")

        return try ListWithTodoCounts.fetchAll(database, request)
    }
}

class ListViewModel {
    let grdb: DatabasePool
    let errorModel: ErrorViewModel
    let supabaseModel: SupabaseViewModel

    init(
        grdb: DatabasePool,
        errorModel: ErrorViewModel,
        supabaseModel: SupabaseViewModel
    ) {
        self.grdb = grdb
        self.errorModel = errorModel
        self.supabaseModel = supabaseModel
    }

    func createList(name: String) throws {
        try errorModel.withReporting("Could not create list") {
            guard let userId = supabaseModel.session?.user.id.uuidString else {
                throw NSError(domain: "AppError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No userId or session found"])
            }
            try grdb.write { database in
                try List(
                    id: UUID().uuidString,
                    name: name,
                    ownerId: userId
                ).insert(database)
            }
        }
    }

    func deleteList(id: String) throws {
        try errorModel.withReporting("Could not delete list") {
            try grdb.write { database in
                /// This should automatically delete all the todos due to the hasMany relationship
                try List.deleteOne(
                    database,
                    key: id
                )
            }
        }
    }
}
