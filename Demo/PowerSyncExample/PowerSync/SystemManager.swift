import Foundation
import PowerSync

@Observable
class SystemManager {
    let connector = SupabaseConnector()
    let schema = AppSchema
    var db: PowerSyncDatabaseProtocol!

    // openDb must be called before connect
    func openDb() {
        db = PowerSyncDatabase(schema: schema, dbFilename: "powersync-swift.sqlite")
    }

    func connect() async {
        do {
            try await db.connect(connector: connector)
        } catch {
            print("Unexpected error: \(error.localizedDescription)") // Catches any other error
        }
    }

    func version() async -> String  {
        do {
            return try await db.getPowerSyncVersion()
        } catch {
            return error.localizedDescription
        }
    }

    func signOut() async throws -> Void {
        try await Task.detached(priority: .userInitiated) {
            try await self.db.disconnectAndClear()
            try await self.connector.client.auth.signOut()
        }.value
    }

    func watchLists(_ callback: @escaping (_ lists: [ListContent]) -> Void ) async {
        Task.detached(priority: .high) {
            do {
                for try await lists in try self.db.watch<ListContent>(
                    sql: "SELECT * FROM \(LISTS_TABLE)",
                    parameters: [],
                    mapper: { cursor in
                        try ListContent(
                            id: cursor.getString(name: "id"),
                            name: cursor.getString(name: "name"),
                            createdAt: cursor.getString(name: "created_at"),
                            ownerId: cursor.getString(name: "owner_id")
                        )
                    }
                ) {
                    callback(lists)
                }
            } catch {
                print("Error in watch: \(error)")
            }
        }
    }

    func insertList(_ list: NewListContent) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try await self.db.execute(
                sql: "INSERT INTO \(LISTS_TABLE) (id, created_at, name, owner_id) VALUES (uuid(), datetime(), ?, ?)",
                parameters: [list.name, self.connector.currentUserID]
            )
        }.value
    }

    func deleteList(id: String) async throws {
         try await Task.detached(priority: .userInitiated) {
             _ = try await self.db.writeTransaction(callback: { transaction in
                 _ = try transaction.execute(
                     sql: "DELETE FROM \(LISTS_TABLE) WHERE id = ?",
                     parameters: [id]
                 )
                 _ = try transaction.execute(
                     sql: "DELETE FROM \(TODOS_TABLE) WHERE list_id = ?",
                     parameters: [id]
                 )
                 return
             })
         }.value
     }

    func watchTodos(_ listId: String, _ callback: @escaping (_ todos: [Todo]) -> Void ) async {
        Task.detached(priority: .high) {
            do {
                for try await todos in try self.db.watch(
                    sql: "SELECT * FROM \(TODOS_TABLE) WHERE list_id = ?",
                    parameters: [listId],
                    mapper: { cursor in
                        try Todo(
                            id: cursor.getString(name: "id"),
                            listId: cursor.getString(name: "list_id"),
                            photoId: cursor.getStringOptional(name: "photo_id"),
                            description: cursor.getString(name: "description"),
                            isComplete: cursor.getBoolean(name: "completed"),
                            createdAt: cursor.getString(name: "created_at"),
                            completedAt: cursor.getStringOptional(name: "completed_at"),
                            createdBy: cursor.getStringOptional(name: "created_by"),
                            completedBy: cursor.getStringOptional(name: "completed_by")
                        )
                    }
                ) {
                    callback(todos)
                }
            } catch {
                print("Error in watch: \(error)")
            }
        }
    }

    func insertTodo(_ todo: NewTodo, _ listId: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try await self.db.execute(
                sql: "INSERT INTO \(TODOS_TABLE) (id, created_at, created_by, description, list_id, completed) VALUES (uuid(), datetime(), ?, ?, ?, ?)",
                parameters: [self.connector.currentUserID, todo.description, listId, todo.isComplete]
            )
        }.value
    }


    func insertManyTodos(listId: String, onProgress: @escaping (Double) -> Void = { _ in }, totalTodos: Int = 2000) async throws {
        try await Task.detached(priority: .userInitiated) {
            for i in 1...totalTodos {
                let todo = NewTodo(listId: listId, isComplete: false, description: "Todo #\(i)")
                try await self.insertTodo(todo, listId)

                let progress = Double(i) / Double(totalTodos)
                await MainActor.run {
                    onProgress(progress)
                }
            }
        }.value
    }

    func updateTodo(_ todo: Todo) async throws {
        try await Task.detached(priority: .userInitiated) {
            if(todo.isComplete) {
                _ = try await self.db.execute(
                    sql: "UPDATE \(TODOS_TABLE) SET description = ?, completed = ?, completed_at = datetime(), completed_by = ? WHERE id = ?",
                    parameters: [todo.description, todo.isComplete, self.connector.currentUserID, todo.id]
                )
            } else {
                _ = try await self.db.execute(
                    sql: "UPDATE \(TODOS_TABLE) SET description = ?, completed = ?, completed_at = NULL, completed_by = NULL WHERE id = ?",
                    parameters: [todo.description, todo.isComplete, todo.id]
                )
            }
        }.value
    }

    func deleteTodo(id: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try await self.db.writeTransaction(callback: { transaction in
                try transaction.execute(
                    sql: "DELETE FROM \(TODOS_TABLE) WHERE id = ?",
                    parameters: [id]
                )
            })
        }.value
    }
}
