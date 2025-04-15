import Foundation

/// Service which manages attachment records.
public actor AttachmentService {
    private let db: any PowerSyncDatabaseProtocol
    private let tableName: String
    private let logger: any LoggerProtocol
    private let logTag = "AttachmentService"

    private let context: AttachmentContext

    /// Actor isolation does not automatically queue [withLock] async operations
    /// These variables are used to ensure FIFO serial queing
    private var lockQueue: [CheckedContinuation<Void, Never>] = []
    private var isLocked = false

    /// Initializes the attachment service with the specified database, table name, logger, and max archived count.
    public init(
        db: PowerSyncDatabaseProtocol,
        tableName: String,
        logger: any LoggerProtocol,
        maxArchivedCount: Int64
    ) {
        self.db = db
        self.tableName = tableName
        self.logger = logger
        context = AttachmentContext(
            db: db,
            tableName: tableName,
            logger: logger,
            maxArchivedCount: maxArchivedCount
        )
    }

    /// Watches for changes to the attachments table.
    public func watchActiveAttachments() throws -> AsyncThrowingStream<[String], Error> {
        logger.info("Watching attachments...", tag: logTag)

        return try db.watch(
            sql: """
            SELECT 
                id 
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
            try cursor.getString(name: "id")
        }
    }

    /// Executes a callback with exclusive access to the attachment context.
    public func withLock<R>(callback: @Sendable @escaping (AttachmentContext) async throws -> R) async throws -> R {
         // If locked, join the queue
         if isLocked {
             await withCheckedContinuation { continuation in
                 lockQueue.append(continuation)
             }
         }
         
         // Now we have the lock
         isLocked = true
        
         do {
             let result = try await callback(context)
             // Release lock and notify next in queue
             releaseLock()
             return result
         } catch {
             // Release lock and notify next in queue
             releaseLock()
             throw error
         }
     }
     
     private func releaseLock() {
         if let next = lockQueue.first {
             lockQueue.removeFirst()
             next.resume()
         } else {
             isLocked = false
         }
     }
}
