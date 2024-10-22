import Foundation
import PowerSync

typealias SuspendHandle = () async throws -> Any?

class PowerSync {
    let factory = DatabaseDriverFactory()
    var db: PowerSyncDatabase!

    func openDb() {
        db = PowerSyncDatabase(factory: factory, schema: schema, dbFilename: "powersync-swift.sqlite")
    }
    
    func watch <T: Codable> (_ sql: String, parameters: [String: Any] = [:], mapper: @escaping (Cursor) throws -> T) async -> AnyPublisher<[T], Never> {
    }
    
    func execute(_ sql: String, parameters: [String: Any] = [:]) async throws {
        try await db.execute(sql: sql, parameters: parameters)
    }

    func writeTransaction(_ queryHandle: @escaping () async throws -> Any) async throws -> Any? {
        try await db.writeTransaction(callback: SuspendTaskWrapper(queryHandle))
    }

    func readTransaction(_ queryHandle: @escaping () async throws -> Any) async throws -> Any? {
        try await db.readTransaction(callback: SuspendTaskWrapper(queryHandle))
    }



    func insertList(_ list: NewListContent) async throws {
        try await self.db.execute(
            sql: "INSERT INTO \(LISTS_TABLE) (id, created_at, name, owner_id) VALUES (uuid(), datetime(), ?, ?)",
            parameters: [list.name, connector.currentUserID]
        )
    }

    func deleteList(id: String) async throws {
        try await db.writeTransaction(callback: SuspendTaskWrapper {
            try await self.db.execute(
                sql: "DELETE FROM \(LISTS_TABLE) WHERE id = ?",
                parameters: [id]
            )
            try await self.db.execute(
                sql: "DELETE FROM \(TODOS_TABLE) WHERE list_id = ?",
                parameters: [id]
            )
            return
        })
    }

    func watchTodos(_ listId: String, _ cb: @escaping (_ todos: [Todo]) -> Void ) async {
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
            cb(todos as! [Todo])
        }
    }

    func insertTodo(_ todo: NewTodo, _ listId: String) async throws {
        try await self.db.execute(
            sql: "INSERT INTO \(TODOS_TABLE) (id, created_at, created_by, description, list_id, completed) VALUES (uuid(), datetime(), ?, ?, ?, ?)",
            parameters: [connector.currentUserID, todo.description, listId, todo.isComplete]
        )
    }

    func updateTodo(_ todo: Todo) async throws {
        // Do this to avoid needing to handle date time from Swift to Kotlin
        if(todo.isComplete) {
            try await self.db.execute(
                sql: "UPDATE \(TODOS_TABLE) SET description = ?, completed = ?, completed_at = datetime(), completed_by = ? WHERE id = ?",
                parameters: [todo.description, todo.isComplete, connector.currentUserID, todo.id]
            )
        } else {
            try await self.db.execute(
                sql: "UPDATE \(TODOS_TABLE) SET description = ?, completed = ?, completed_at = NULL, completed_by = NULL WHERE id = ?",
                parameters: [todo.description, todo.isComplete, todo.id]
            )
        }
    }

    func deleteTodo(id: String) async throws {
        try await db.writeTransaction(callback: SuspendTaskWrapper {
            try await self.db.execute(
                sql: "DELETE FROM \(TODOS_TABLE) WHERE id = ?",
                parameters: [id]
            )
            return
        })
    }
}

class SuspendTaskWrapper: KotlinSuspendFunction1 {
    let handle: () async throws -> Any

    init(_ handle: @escaping () async throws -> Any) {
        self.handle = handle
    }

    @MainActor
    func invoke(p1: Any?, completionHandler: @escaping (Any?, Error?) -> Void) {
        Task {
            do {
                let result = try await self.handle()
                completionHandler(result, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }
}
import Foundation
import PowerSync

typealias SuspendHandle = () async throws -> Any?

@Observable
@MainActor
class PowerSync {
    let factory = DatabaseDriverFactory()
    let connector = SupabaseConnector()
    let schema = AppSchema
    var db: PowerSyncDatabase!

    func openDb() {
        db = PowerSyncDatabase(factory: factory, schema: schema, dbFilename: "powersync-swift.sqlite")
    }

    // openDb must be called before connect
    func connect() async {
        do {
            try await db.connect(connector: connector, crudThrottleMs: 1000, retryDelayMs:5000, params: [:])
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
        try await db.disconnectAndClear(clearLocal: true)
        try await connector.client.auth.signOut()
    }

    func writeTransaction(_ queryHandle: @escaping () async throws -> Any) async throws -> Any? {
        try await db.writeTransaction(callback: SuspendTaskWrapper(queryHandle))
    }

    func readTransaction(_ queryHandle: @escaping () async throws -> Any) async throws -> Any? {
        try await db.readTransaction(callback: SuspendTaskWrapper(queryHandle))
    }

    func watchLists(_ cb: @escaping (_ lists: [ListContent]) -> Void ) async {
        for await lists in self.db.watch(
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
            cb(lists as! [ListContent])
        }
    }

    func insertList(_ list: NewListContent) async throws {
        try await self.db.execute(
            sql: "INSERT INTO \(LISTS_TABLE) (id, created_at, name, owner_id) VALUES (uuid(), datetime(), ?, ?)",
            parameters: [list.name, connector.currentUserID]
        )
    }

    func deleteList(id: String) async throws {
        try await db.writeTransaction(callback: SuspendTaskWrapper {
            try await self.db.execute(
                sql: "DELETE FROM \(LISTS_TABLE) WHERE id = ?",
                parameters: [id]
            )
            try await self.db.execute(
                sql: "DELETE FROM \(TODOS_TABLE) WHERE list_id = ?",
                parameters: [id]
            )
            return
        })
    }

    func watchTodos(_ listId: String, _ cb: @escaping (_ todos: [Todo]) -> Void ) async {
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
            cb(todos as! [Todo])
        }
    }

    func insertTodo(_ todo: NewTodo, _ listId: String) async throws {
        try await self.db.execute(
            sql: "INSERT INTO \(TODOS_TABLE) (id, created_at, created_by, description, list_id, completed) VALUES (uuid(), datetime(), ?, ?, ?, ?)",
            parameters: [connector.currentUserID, todo.description, listId, todo.isComplete]
        )
    }

    func updateTodo(_ todo: Todo) async throws {
        // Do this to avoid needing to handle date time from Swift to Kotlin
        if(todo.isComplete) {
            try await self.db.execute(
                sql: "UPDATE \(TODOS_TABLE) SET description = ?, completed = ?, completed_at = datetime(), completed_by = ? WHERE id = ?",
                parameters: [todo.description, todo.isComplete, connector.currentUserID, todo.id]
            )
        } else {
            try await self.db.execute(
                sql: "UPDATE \(TODOS_TABLE) SET description = ?, completed = ?, completed_at = NULL, completed_by = NULL WHERE id = ?",
                parameters: [todo.description, todo.isComplete, todo.id]
            )
        }
    }

    func deleteTodo(id: String) async throws {
        try await db.writeTransaction(callback: SuspendTaskWrapper {
            try await self.db.execute(
                sql: "DELETE FROM \(TODOS_TABLE) WHERE id = ?",
                parameters: [id]
            )
            return
        })
    }
}

class SuspendTaskWrapper: KotlinSuspendFunction1 {
    let handle: () async throws -> Any

    init(_ handle: @escaping () async throws -> Any) {
        self.handle = handle
    }

    @MainActor
    func invoke(p1: Any?, completionHandler: @escaping (Any?, Error?) -> Void) {
        Task {
            do {
                let result = try await self.handle()
                completionHandler(result, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }
}
