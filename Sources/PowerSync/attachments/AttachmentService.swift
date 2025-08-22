import Foundation

public protocol AttachmentService: Sendable {
    /// Watches for changes to the attachments table.
    func watchActiveAttachments() async throws -> AsyncThrowingStream<[String], Error>

    /// Executes a callback with exclusive access to the attachment context.
    func withContext<R: Sendable>(
        callback: @Sendable @escaping (AttachmentContext) async throws -> R
    ) async throws -> R
}

/// Service which manages attachment records.
actor AttachmentServiceImpl: AttachmentService {
    private let db: any PowerSyncDatabaseProtocol
    private let tableName: String
    private let logger: any LoggerProtocol
    private let logTag = "AttachmentService"

    private let context: AttachmentContext

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
        context = AttachmentContextImpl(
            db: db,
            tableName: tableName,
            logger: logger,
            maxArchivedCount: maxArchivedCount
        )
    }

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
                AttachmentState.queuedDelete.rawValue
            ]
        ) { cursor in
            try cursor.getString(name: "id")
        }
    }

    public func withContext<R: Sendable>(callback: @Sendable @escaping (AttachmentContext) async throws -> R) async throws -> R {
        try await callback(context)
    }
}
