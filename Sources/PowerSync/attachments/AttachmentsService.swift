import Foundation

// TODO: should not need this
import PowerSyncKotlin

/**
 * Service for interacting with the local attachment records.
 */
public class AttachmentService {
    private let db: any PowerSyncDatabaseProtocol
    private let tableName: String
    private let logger: any LoggerProtocol
    private let logTag = "AttachmentService"
    private let maxArchivedCount: Int64

    /**
     * Table used for storing attachments in the attachment queue.
     */
    private var table: String {
        return tableName
    }

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

    /**
     * Delete the attachment from the attachment queue.
     */
    public func deleteAttachment(id: String) async throws {
        _ = try await db.execute(sql: "DELETE FROM \(table) WHERE id = ?", parameters: [id])
    }

    /**
     * Set the state of the attachment to ignore.
     */
    public func ignoreAttachment(id: String) async throws {
        _ = try await db.execute(
            sql: "UPDATE \(table) SET state = ? WHERE id = ?",
            parameters: [AttachmentState.archived.rawValue, id]
        )
    }

    /**
     * Get the attachment from the attachment queue using an ID.
     */
    public func getAttachment(id: String) async throws -> Attachment? {
        return try await db.getOptional(sql: "SELECT * FROM \(table) WHERE id = ?", parameters: [id], mapper: { cursor in
            try Attachment.fromCursor(cursor)
        })
    }

    /**
     * Save the attachment to the attachment queue.
     */
    public func saveAttachment(attachment: Attachment) async throws -> Attachment {
        return try await db.writeTransaction { ctx in
            try self.upsertAttachment(attachment, context: ctx)
        }
    }

    /**
     * Save the attachments to the attachment queue.
     */
    public func saveAttachments(attachments: [Attachment]) async throws {
        if attachments.isEmpty {
            return
        }

        try await db.writeTransaction { tx in
            for attachment in attachments {
                _ = try self.upsertAttachment(attachment, context: tx)
            }
        }
    }

    /**
     * Get all the ID's of attachments in the attachment queue.
     */
    public func getAttachmentIds() async throws -> [String] {
        return try await db.getAll(
            sql: "SELECT id FROM \(table) WHERE id IS NOT NULL",
            parameters: [],
            mapper: { cursor in
                try cursor.getString(name: "id")
            }
        )
    }

    public func getAttachments() async throws -> [Attachment] {
        return try await db.getAll(
            sql: """
            SELECT 
                * 
            FROM 
                \(table) 
            WHERE 
                id IS NOT NULL
            ORDER BY 
                timestamp ASC
            """,
            parameters: [],
            mapper: { cursor in
                try Attachment.fromCursor(cursor)
            }
        )
    }

    /**
     * Gets all the active attachments which require an operation to be performed.
     */
    public func getActiveAttachments() async throws -> [Attachment] {
        return try await db.getAll(
            sql: """
            SELECT 
                *
            FROM
                \(table) 
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

    /**
     * Watcher for changes to attachments table.
     * Once a change is detected it will initiate a sync of the attachments
     */
    public func watchActiveAttachments() throws -> AsyncThrowingStream<[String], Error> {
        logger.info("Watching attachments...", tag: logTag)

        return try db.watch(
            sql: """
            SELECT 
                id 
            FROM 
                \(table)
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
            try cursor.getString(name: "id")
        }
    }

    /**
     * Helper function to clear the attachment queue
     * Currently only used for testing purposes.
     */
    public func clearQueue() async throws {
        // logger.i("Clearing attachment queue...")
        _ = try await db.execute("DELETE FROM \(table)")
    }

    /**
     * Delete attachments which have been archived
     * @returns true if all items have been deleted. Returns false if there might be more archived
     * items remaining.
     */
    public func deleteArchivedAttachments(callback: @escaping ([Attachment]) async throws -> Void) async throws -> Bool {
        // First fetch the attachments in order to allow other cleanup
        let limit = 1000
        let attachments = try await db.getAll(
            sql: """
            SELECT
                * 
            FROM 
                \(table)
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
            sql: "DELETE FROM \(table) WHERE id IN (SELECT value FROM json_each(?));",
            parameters: [idsString]
        )

        return attachments.count < limit
    }

    /**
     * Upserts an attachment record synchronously given a database connection context.
     */
    public func upsertAttachment(
        _ attachment: Attachment,
        context: PowerSyncTransaction
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
            size: attachment.size,
        )

        try context.execute(
            sql: """
            INSERT OR REPLACE INTO 
                \(table) (id, timestamp, filename, local_uri, media_type, size, state, has_synced) 
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                updatedRecord.id,
                updatedRecord.timestamp,
                updatedRecord.filename,
                updatedRecord.localUri as Any,
                updatedRecord.mediaType ?? NSNull(),
                updatedRecord.size ?? NSNull(),
                updatedRecord.state,
                updatedRecord.hasSynced ?? 0,
            ]
        )

        return attachment
    }
}
