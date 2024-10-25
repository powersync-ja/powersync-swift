import Foundation
import PowerSyncSwift

@Observable
@MainActor
class PowerSyncManager {
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
                    id: cursor.getString(index: 0)!,
                    name: cursor.getString(index: 1)!,
                    createdAt: cursor.getString(index: 2)!,
                    ownerId: cursor.getString(index: 3)!
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
        try await db.writeTransaction(callback: { transaction in
            _ = try await transaction.execute(
                sql: "DELETE FROM \(LISTS_TABLE) WHERE id = ?",
                parameters: [id]
            )
            _ = try await transaction.execute(
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
                    id: cursor.getString(index: 0)!,
                    listId: cursor.getString(index: 1)!,
                    photoId: cursor.getString(index: 2),
                    description: cursor.getString(index: 3)!,
                    isComplete: cursor.getBoolean(index: 4)! as! Bool,
                    createdAt: cursor.getString(index: 5),
                    completedAt: cursor.getString(index: 6),
                    createdBy: cursor.getString(index: 7),
                    completedBy: cursor.getString(index: 8)
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
        try await db.writeTransaction(callback: { transaction in
            _ = try await transaction.execute(
                    sql: "DELETE FROM \(TODOS_TABLE) WHERE id = ?",
                    parameters: [id]
                )
            return
        })
    }
}


