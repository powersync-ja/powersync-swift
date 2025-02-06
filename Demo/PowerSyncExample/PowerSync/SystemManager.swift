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
        try await db.disconnectAndClear()
        try await connector.client.auth.signOut()
    }

    func watchLists(_ callback: @escaping (_ lists: [ListContent]) -> Void ) async {
        for await lists in self.db.watch<[ListContent]>(
            sql: "SELECT * FROM \(LISTS_TABLE)",
            parameters: [],
            mapper: { cursor in
                ListContent(
                    id: try cursor.getString(name: "id"),
                    name: try cursor.getString(name: "name"),
                    createdAt: try cursor.getString(name: "created_at"),
                    ownerId: try cursor.getString(name: "owner_id")
                )
            }
        ) {
            callback(lists)
        }
    }

    func insertList(_ list: NewListContent) async throws {
        _ = try await self.db.execute(
            sql: "INSERT INTO \(LISTS_TABLE) (id, created_at, name, owner_id) VALUES (uuid(), datetime(), ?, ?)",
            parameters: [list.name, connector.currentUserID]
        )
    }

    func deleteList(id: String) async throws {
        _ = try await db.writeTransaction(callback: { transaction in
            _ = transaction.execute(
                sql: "DELETE FROM \(LISTS_TABLE) WHERE id = ?",
                parameters: [id]
            )
            _ = transaction.execute(
                sql: "DELETE FROM \(TODOS_TABLE) WHERE list_id = ?",
                parameters: [id]
            )
            return
        })
    }

    func watchTodos(_ listId: String, _ callback: @escaping (_ todos: [Todo]) -> Void ) async {
        for await todos in self.db.watch(
            sql: "SELECT * FROM \(TODOS_TABLE) WHERE list_id = ?",
            parameters: [listId],
            mapper: { cursor in
                return Todo(
                    id: try cursor.getString(name: "id"),
                    listId: try cursor.getString(name: "list_id"),
                    photoId: try cursor.getStringOptional(name: "photo_id"),
                    description: try cursor.getString(name: "description"),
                    isComplete: try cursor.getBoolean(name: "completed"),
                    createdAt: try cursor.getString(name: "created_at"),
                    completedAt: try cursor.getStringOptional(name: "completed_at"),
                    createdBy: try cursor.getStringOptional(name: "created_by"),
                    completedBy: try cursor.getStringOptional(name: "completed_by")
                )
            }
        ) {
            callback(todos)
        }
    }

    func insertTodo(_ todo: NewTodo, _ listId: String) async throws {
        _ = try await self.db.execute(
            sql: "INSERT INTO \(TODOS_TABLE) (id, created_at, created_by, description, list_id, completed) VALUES (uuid(), datetime(), ?, ?, ?, ?)",
            parameters: [connector.currentUserID, todo.description, listId, todo.isComplete]
        )
    }

    func updateTodo(_ todo: Todo) async throws {
        // Do this to avoid needing to handle date time from Swift to Kotlin
        if(todo.isComplete) {
            _ = try await self.db.execute(
                sql: "UPDATE \(TODOS_TABLE) SET description = ?, completed = ?, completed_at = datetime(), completed_by = ? WHERE id = ?",
                parameters: [todo.description, todo.isComplete, connector.currentUserID, todo.id]
            )
        } else {
            _ = try await self.db.execute(
                sql: "UPDATE \(TODOS_TABLE) SET description = ?, completed = ?, completed_at = NULL, completed_by = NULL WHERE id = ?",
                parameters: [todo.description, todo.isComplete, todo.id]
            )
        }
    }

    func deleteTodo(id: String) async throws {
        _ = try await db.writeTransaction(callback: { transaction in
            transaction.execute(
                sql: "DELETE FROM \(TODOS_TABLE) WHERE id = ?",
                parameters: [id]
            )
        })
    }
}
