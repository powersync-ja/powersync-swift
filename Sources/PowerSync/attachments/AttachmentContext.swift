import Foundation

public protocol AttachmentContext: Sendable {
    var db: any PowerSyncDatabaseProtocol { get }
    var tableName: String { get }
    var logger: any LoggerProtocol { get }
    var maxArchivedCount: Int64 { get }

    /// Deletes the attachment from the attachment queue.
    func deleteAttachment(id: String) async throws

    /// Sets the state of the attachment to ignored (archived).
    func ignoreAttachment(id: String) async throws

    /// Gets the attachment from the attachment queue using an ID.
    func getAttachment(id: String) async throws -> Attachment?

    /// Saves the attachment to the attachment queue.
    func saveAttachment(attachment: Attachment) async throws -> Attachment

    /// Saves multiple attachments to the attachment queue.
    func saveAttachments(attachments: [Attachment]) async throws

    /// Gets all the IDs of attachments in the attachment queue.
    func getAttachmentIds() async throws -> [String]

    /// Gets all attachments in the attachment queue.
    func getAttachments() async throws -> [Attachment]

    /// Gets all active attachments that require an operation to be performed.
    func getActiveAttachments() async throws -> [Attachment]

    /// Deletes attachments that have been archived.
    ///
    /// - Parameter callback: A callback invoked with the list of archived attachments before deletion.
    /// - Returns: `true` if all items have been deleted, `false` if there may be more archived items remaining.
    func deleteArchivedAttachments(
        callback: @Sendable @escaping ([Attachment]) async throws -> Void
    ) async throws -> Bool

    /// Clears the attachment queue.
    ///
    /// - Note: Currently only used for testing purposes.
    func clearQueue() async throws
}

public extension AttachmentContext {
    func deleteAttachment(id: String) async throws {
        _ = try await db.execute(
            sql: "DELETE FROM \(tableName) WHERE id = ?",
            parameters: [id]
        )
    }

    func ignoreAttachment(id: String) async throws {
        _ = try await db.execute(
            sql: "UPDATE \(tableName) SET state = ? WHERE id = ?",
            parameters: [AttachmentState.archived.rawValue, id]
        )
    }

    func getAttachment(id: String) async throws -> Attachment? {
        return try await db.getOptional(
            sql: "SELECT * FROM \(tableName) WHERE id = ?",
            parameters: [id]
        ) { cursor in
            try Attachment.fromCursor(cursor)
        }
    }

    func saveAttachment(attachment: Attachment) async throws -> Attachment {
        return try await db.writeTransaction { ctx in
            try self.upsertAttachment(attachment, context: ctx)
        }
    }

    func saveAttachments(attachments: [Attachment]) async throws {
        if attachments.isEmpty {
            return
        }

        try await db.writeTransaction { tx in
            for attachment in attachments {
                _ = try self.upsertAttachment(attachment, context: tx)
            }
        }
    }

    func getAttachmentIds() async throws -> [String] {
        return try await db.getAll(
            sql: "SELECT id FROM \(tableName) WHERE id IS NOT NULL",
            parameters: []
        ) { cursor in
            try cursor.getString(name: "id")
        }
    }

    func getAttachments() async throws -> [Attachment] {
        return try await db.getAll(
            sql: """
            SELECT 
                * 
            FROM 
                \(tableName) 
            WHERE 
                id IS NOT NULL
            ORDER BY 
                timestamp ASC
            """,
            parameters: []
        ) { cursor in
            try Attachment.fromCursor(cursor)
        }
    }

    func getActiveAttachments() async throws -> [Attachment] {
        return try await db.getAll(
            sql: """
            SELECT 
                *
            FROM
                \(tableName) 
            WHERE 
                state = ?
                OR state = ?
                OR state = ?
            ORDER BY 
                timestamp ASC
            """,
            parameters: [
                AttachmentState.queuedUpload.rawValue,
                AttachmentState.queuedDownload.rawValue,
                AttachmentState.queuedDelete.rawValue,
            ]
        ) { cursor in
            try Attachment.fromCursor(cursor)
        }
    }

    func clearQueue() async throws {
        _ = try await db.execute("DELETE FROM \(tableName)")
    }

    func deleteArchivedAttachments(callback: @Sendable @escaping ([Attachment]) async throws -> Void) async throws -> Bool {
        let limit = 1000
        let attachments = try await db.getAll(
            sql: """
            SELECT
                * 
            FROM 
                \(tableName)
            WHERE 
                state = ?
            ORDER BY
                timestamp DESC
            LIMIT ? OFFSET ?
            """,
            parameters: [
                AttachmentState.archived.rawValue,
                limit,
                maxArchivedCount,
            ]
        ) { cursor in
            try Attachment.fromCursor(cursor)
        }

        try await callback(attachments)

        let ids = try JSONEncoder().encode(attachments.map { $0.id })
        let idsString = String(data: ids, encoding: .utf8)!

        _ = try await db.execute(
            sql: "DELETE FROM \(tableName) WHERE id IN (SELECT value FROM json_each(?));",
            parameters: [idsString]
        )

        return attachments.count < limit
    }

    /// Upserts an attachment record synchronously using a database transaction context.
    ///
    /// - Parameters:
    ///   - attachment: The attachment to upsert.
    ///   - context: The database transaction context.
    /// - Returns: The original attachment.
    func upsertAttachment(
        _ attachment: Attachment,
        context: ConnectionContext
    ) throws -> Attachment {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let updatedRecord = Attachment(
            id: attachment.id,
            filename: attachment.filename,
            state: attachment.state,
            timestamp: timestamp,
            hasSynced: attachment.hasSynced,
            localUri: attachment.localUri,
            mediaType: attachment.mediaType,
            size: attachment.size
        )

        try context.execute(
            sql: """
            INSERT OR REPLACE INTO 
                \(tableName) (id, timestamp, filename, local_uri, media_type, size, state, has_synced, meta_data) 
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                updatedRecord.id,
                updatedRecord.timestamp,
                updatedRecord.filename,
                updatedRecord.localUri,
                updatedRecord.mediaType,
                updatedRecord.size,
                updatedRecord.state.rawValue,
                updatedRecord.hasSynced ?? 0,
                updatedRecord.metaData
            ]
        )

        return attachment
    }
}

/// Context which performs actions on the attachment records
public actor AttachmentContextImpl: AttachmentContext {
    public let db: any PowerSyncDatabaseProtocol
    public let tableName: String
    public let logger: any LoggerProtocol
    public let maxArchivedCount: Int64

    public init(
        db: PowerSyncDatabaseProtocol,
        tableName: String,
        logger: any LoggerProtocol,
        maxArchivedCount: Int64
    ) {
        self.db = db
        self.tableName = tableName
        self.logger = logger
        self.maxArchivedCount = maxArchivedCount
    }
}
