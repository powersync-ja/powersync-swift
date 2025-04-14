import Foundation
import PowerSync

func getAttachmentsDirectoryPath() throws -> String {
    guard let documentsURL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first else {
        throw PowerSyncError.attachmentError("Could not determine attachments directory path")
    }
    return documentsURL.appendingPathComponent("attachments").path
}

@Observable
class SystemManager {
    let connector = SupabaseConnector()
    let schema = AppSchema
    let db: PowerSyncDatabaseProtocol
    let attachments: AttachmentQueue?

    init() {
        db = PowerSyncDatabase(
            schema: schema,
            dbFilename: "powersync-swift.sqlite"
        )
        // Try and configure attachments
        do {
            let attachmentsDir = try getAttachmentsDirectoryPath()
            let watchedAttachments = try db.watch(
                options: WatchOptions(
                    sql: "SELECT photo_id FROM \(TODOS_TABLE) WHERE photo_id IS NOT NULL",
                    parameters: [],
                    mapper: { cursor in
                        try WatchedAttachmentItem(
                            id: cursor.getString(name: "photo_id"),
                            fileExtension: "jpg"
                        )
                    }
                )
            )

            attachments = AttachmentQueue(
                db: db,
                remoteStorage: SupabaseRemoteStorage(storage: connector.getStorageBucket()),
                attachmentsDirectory: attachmentsDir,
                watchedAttachments: watchedAttachments
            )
        } catch {
            print("Failed to initialize attachments queue: \(error)")
            attachments = nil
        }
    }

    func connect() async {
        do {
            // Only for testing purposes
            try await attachments?.clearQueue()
            try await db.connect(connector: connector)
            try await attachments?.startSync()
        } catch {
            print("Unexpected error: \(error.localizedDescription)") // Catches any other error
        }
    }

    func version() async -> String {
        do {
            return try await db.getPowerSyncVersion()
        } catch {
            return error.localizedDescription
        }
    }

    func signOut() async throws {
        try await db.disconnectAndClear()
        try await connector.client.auth.signOut()
        try await attachments?.clearQueue()
        try await attachments?.close()
    }

    func watchLists(_ callback: @escaping (_ lists: [ListContent]) -> Void) async {
        do {
            for try await lists in try db.watch<ListContent>(
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
        let result = try await db.execute(
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
        })
    }

    func watchTodos(_ listId: String, _ callback: @escaping (_ todos: [Todo]) -> Void) async {
        do {
            for try await todos in try db.watch(
                sql: """
                  SELECT 
                      t.*, a.local_uri
                  FROM
                      \(TODOS_TABLE) t
                      LEFT JOIN attachments a ON t.photo_id = a.id
                  WHERE 
                      t.list_id = ?
                  ORDER BY t.id;
                """,
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
                        completedBy: cursor.getStringOptional(name: "completed_by"),
                        photoUri: cursor.getStringOptional(name: "local_uri")
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
        _ = try await db.execute(
            sql: "INSERT INTO \(TODOS_TABLE) (id, created_at, created_by, description, list_id, completed) VALUES (uuid(), datetime(), ?, ?, ?, ?)",
            parameters: [connector.currentUserID, todo.description, listId, todo.isComplete]
        )
    }

    func updateTodo(_ todo: Todo) async throws {
        // Do this to avoid needing to handle date time from Swift to Kotlin
        if todo.isComplete {
            _ = try await db.execute(
                sql: "UPDATE \(TODOS_TABLE) SET description = ?, completed = ?, completed_at = datetime(), completed_by = ? WHERE id = ?",
                parameters: [todo.description, todo.isComplete, connector.currentUserID, todo.id]
            )
        } else {
            _ = try await db.execute(
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
}
