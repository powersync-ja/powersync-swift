import Foundation
import PowerSync


@Observable
class SystemManager {
    let connector = SupabaseConnector()
    let schema = AppSchema
    var db: PowerSyncDatabaseProtocol!

    // openDb must be called before connect
    func openDb() async throws {
        db = PowerSyncDatabase(schema: schema, dbFilename: "powersync-swift.sqlite")
        do {
            try await configureFts(db: db, schema: schema)
        } catch {
            print("Failed to configure FTS: \(error.localizedDescription)")
            
        }
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
        do {
            for try await lists in try self.db.watch<ListContent>(
                options: WatchOptions(
                    sql: "SELECT * FROM \(LISTS_TABLE)",
                    mapper: { cursor in
                        try ListContent(
                            id: cursor.getString(name: "id"),
                            name: cursor.getString(name: "name"),
                            createdAt: cursor.getString(name: "created_at"),
                            ownerId: cursor.getString(name: "owner_id")
                        )
                    }
                )
            ) {
                callback(lists)
            }
        } catch {
            print("Error in watch: \(error)")
        }
    }

    func insertList(_ list: NewListContent) async throws {
        let result = try await self.db.execute(
            sql: "INSERT INTO \(LISTS_TABLE) (id, created_at, name, owner_id) VALUES (uuid(), datetime(), ?, ?)",
            parameters: [list.name, connector.currentUserID]
        )
    }

    func deleteList(id: String) async throws {
        _ = try await db.writeTransaction(callback: { transaction in
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
    }

    func watchTodos(_ listId: String, _ callback: @escaping (_ todos: [Todo]) -> Void ) async {
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
            try transaction.execute(
                sql: "DELETE FROM \(TODOS_TABLE) WHERE id = ?",
                parameters: [id]
            )
        })
    }
    
    /// Helper function to prepare the search term for FTS5 query syntax.
    private func createSearchTermWithOptions(_ searchTerm: String) -> String {
        let trimmedSearchTerm = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchTerm.isEmpty else {
            return ""
        }
        return "\(trimmedSearchTerm)*"
    }
    
    /// Searches across lists and todos using FTS.
    ///
    /// - Parameter searchTerm: The text to search for.
    /// - Returns: An array of search results, containing either `ListContent` or `Todo` objects.
    /// - Throws: An error if the database query fails.
    func searchListsAndTodos(searchTerm: String) async throws -> [AnyHashable] {
        let preparedSearchTerm = createSearchTermWithOptions(searchTerm)

        guard !preparedSearchTerm.isEmpty else {
            print("[FTS] Prepared search term is empty, returning no results.")
            return []
        }

        print("[FTS] Searching for term: \(preparedSearchTerm)")

        var results: [AnyHashable] = []

        // --- Search Lists ---
        let listSql = """
            SELECT l.*
            FROM \(LISTS_TABLE) l
            JOIN fts_\(LISTS_TABLE) fts ON l.id = fts.id
            WHERE fts.fts_\(LISTS_TABLE) MATCH ? ORDER BY fts.rank
        """
        do {
            let listsFound = try await db.getAll(
                sql: listSql,
                parameters: [preparedSearchTerm],
                mapper: { cursor in
                    try ListContent(
                        id: cursor.getString(name: "id"),
                        name: cursor.getString(name: "name"),
                        createdAt: cursor.getString(name: "created_at"),
                        ownerId: cursor.getString(name: "owner_id")
                    )
                }
            )
            results.append(contentsOf: listsFound)
            print("[FTS] Found \(listsFound.count) lists matching term.")
        } catch {
            print("[FTS] Error searching lists: \(error.localizedDescription)")
            throw error
        }


        // --- Search Todos ---
        let todoSql = """
            SELECT t.*
            FROM \(TODOS_TABLE) t
            JOIN fts_\(TODOS_TABLE) fts ON t.id = fts.id
            WHERE fts.fts_\(TODOS_TABLE) MATCH ? ORDER BY fts.rank
        """
        do {
            let todosFound = try await db.getAll(
                sql: todoSql,
                parameters: [preparedSearchTerm],
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
            )
            results.append(contentsOf: todosFound)
            print("[FTS] Found \(todosFound.count) todos matching term.")
        } catch {
            print("[FTS] Error searching todos: \(error.localizedDescription)")
            throw error
        }

        print("[FTS] Total results found: \(results.count)")
        return results
    }
}
