import Combine
import Foundation
import OSLog

// TODO: should not need this
import PowerSyncKotlin

/// A watched attachment record item.
/// This is usually returned from watching all relevant attachment IDs.
public struct WatchedAttachmentItem {
    /// Id for the attachment record
    public let id: String

    /// File extension used to determine an internal filename for storage if no `filename` is provided
    public let fileExtension: String?

    /// Filename to store the attachment with
    public let filename: String?

    /// Metadata for the attachment (optional)
    public let metaData: String?

    /// Initializes a new `WatchedAttachmentItem`
    /// - Parameters:
    ///   - id: Attachment record ID
    ///   - fileExtension: Optional file extension
    ///   - filename: Optional filename
    ///   - metaData: Optional metadata
    public init(
        id: String,
        fileExtension: String? = nil,
        filename: String? = nil,
        metaData: String? = nil
    ) {
        self.id = id
        self.fileExtension = fileExtension
        self.filename = filename
        self.metaData = metaData

        precondition(fileExtension != nil || filename != nil, "Either fileExtension or filename must be provided.")
    }
}

/// Class used to implement the attachment queue
/// Requires a PowerSyncDatabase, a RemoteStorageAdapter implementation, and a directory name for attachments.
public actor AttachmentQueue {
    /// Default name of the attachments table
    public static let DEFAULT_TABLE_NAME = "attachments"
    
    let logTag = "AttachmentQueue"

    /// PowerSync database client
    public let db: PowerSyncDatabaseProtocol

    /// Remote storage adapter
    public let remoteStorage: RemoteStorageAdapter

    /// Directory name for attachments
    private let attachmentsDirectory: String

    /// Stream of watched attachments
    private let watchedAttachments: AsyncThrowingStream<[WatchedAttachmentItem], Error>

    /// Local file system adapter
    public let localStorage: LocalStorageAdapter

    /// Attachments table name in SQLite
    private let attachmentsQueueTableName: String

    /// Optional sync error handler
    private let errorHandler: SyncErrorHandler?

    /// Interval between periodic syncs
    private let syncInterval: TimeInterval

    /// Limit on number of archived attachments
    private let archivedCacheLimit: Int64

    /// Duration for throttling sync operations
    private let syncThrottleDuration: TimeInterval

    /// Subdirectories to be created in attachments directory
    private let subdirectories: [String]?

    /// Whether to allow downloading of attachments
    private let downloadAttachments: Bool

    /**
     * Logging interface used for all log operations
     */
    public let logger: any LoggerProtocol

    /// Attachment service for interacting with attachment records
    public let attachmentsService: AttachmentService

    private var syncStatusTask: Task<Void, Error>?
    private var cancellables = Set<AnyCancellable>()

    /// Indicates whether the queue has been closed
    public private(set) var closed: Bool = false

    /// Syncing service instance
    private(set) lazy var syncingService: SyncingService = .init(
        remoteStorage: self.remoteStorage,
        localStorage: self.localStorage,
        attachmentsService: self.attachmentsService,
        logger: self.logger,
        getLocalUri: { [weak self] filename in
            guard let self = self else { return filename }
            return await self.getLocalUri(filename)
        },
        errorHandler: self.errorHandler,
        syncThrottle: self.syncThrottleDuration
    )

    /// Initializes the attachment queue
    /// - Parameters match the stored properties
    public init(
        db: PowerSyncDatabaseProtocol,
        remoteStorage: RemoteStorageAdapter,
        attachmentsDirectory: String,
        watchedAttachments: AsyncThrowingStream<[WatchedAttachmentItem], Error>,
        localStorage: LocalStorageAdapter = FileManagerStorageAdapter(),
        attachmentsQueueTableName: String = DEFAULT_TABLE_NAME,
        errorHandler: SyncErrorHandler? = nil,
        syncInterval: TimeInterval = 30.0,
        archivedCacheLimit: Int64 = 100,
        syncThrottleDuration: TimeInterval = 1.0,
        subdirectories: [String]? = nil,
        downloadAttachments: Bool = true,
        logger: (any LoggerProtocol)? = nil
    ) {
        self.db = db
        self.remoteStorage = remoteStorage
        self.attachmentsDirectory = attachmentsDirectory
        self.watchedAttachments = watchedAttachments
        self.localStorage = localStorage
        self.attachmentsQueueTableName = attachmentsQueueTableName
        self.errorHandler = errorHandler
        self.syncInterval = syncInterval
        self.archivedCacheLimit = archivedCacheLimit
        self.syncThrottleDuration = syncThrottleDuration
        self.subdirectories = subdirectories
        self.downloadAttachments = downloadAttachments
        self.logger = logger ?? db.logger

        attachmentsService = AttachmentService(
            db: db,
            tableName: attachmentsQueueTableName,
            logger: self.logger,
            maxArchivedCount: archivedCacheLimit
        )
    }

    /// Starts the attachment sync process
    public func startSync() async throws {
        if closed {
            throw NSError(domain: "AttachmentError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Attachment queue has been closed"])
        }

        // Ensure the directory where attachments are downloaded exists
        try await localStorage.makeDir(path: attachmentsDirectory)

        if let subdirectories = subdirectories {
            for subdirectory in subdirectories {
                let path = URL(fileURLWithPath: attachmentsDirectory).appendingPathComponent(subdirectory).path
                try await localStorage.makeDir(path: path)
            }
        }

        await syncingService.startPeriodicSync(period: syncInterval)

        syncStatusTask = Task {
            do {
                // Create a task for watching connectivity changes
                let connectivityTask = Task {
                    var previousConnected = db.currentStatus.connected

                    for await status in db.currentStatus.asFlow() {
                        if !previousConnected && status.connected {
                            await syncingService.triggerSync()
                        }
                        previousConnected = status.connected
                    }
                }

                // Create a task for watching attachment changes
                let watchTask = Task {
                    for try await items in self.watchedAttachments {
                        try await self.processWatchedAttachments(items: items)
                    }
                }

                // Wait for both tasks to complete (they shouldn't unless cancelled)
                await connectivityTask.value
                try await watchTask.value
            } catch {
                if !(error is CancellationError) {
                    logger.error("Error in sync job: \(error.localizedDescription)", tag: logTag)
                }
            }
        }
    }

    /// Closes the attachment queue and cancels all sync tasks
    public func close() async throws {
        if closed {
            return
        }

        syncStatusTask?.cancel()
        await syncingService.close()
        closed = true
    }

    /// Resolves the filename for a new attachment
    /// - Parameters:
    ///   - attachmentId: Attachment ID
    ///   - fileExtension: File extension
    /// - Returns: Resolved filename
    public func resolveNewAttachmentFilename(
        attachmentId: String,
        fileExtension: String?
    ) -> String {
        return "\(attachmentId).\(fileExtension ?? "")"
    }

    /// Processes watched attachment items and updates sync state
    /// - Parameter items: List of watched attachment items
    public func processWatchedAttachments(items: [WatchedAttachmentItem]) async throws {
        // Need to get all the attachments which are tracked in the DB.
        // We might need to restore an archived attachment.
        let currentAttachments = try await attachmentsService.getAttachments()
        var attachmentUpdates = [Attachment]()

        for item in items {
            let existingQueueItem = currentAttachments.first { $0.id == item.id }

            if existingQueueItem == nil {
                if !downloadAttachments {
                    continue
                }
                // This item should be added to the queue
                // This item is assumed to be coming from an upstream sync
                // Locally created new items should be persisted using saveFile before
                // this point.
                let filename = resolveNewAttachmentFilename(
                    attachmentId: item.id,
                    fileExtension: item.fileExtension
                )

                attachmentUpdates.append(
                    Attachment(
                        id: item.id,
                        filename: filename,
                        state: AttachmentState.queuedDownload.rawValue
                    )
                )
            } else if existingQueueItem!.state == AttachmentState.archived.rawValue {
                // The attachment is present again. Need to queue it for sync.
                // We might be able to optimize this in future
                if existingQueueItem!.hasSynced == 1 {
                    // No remote action required, we can restore the record (avoids deletion)
                    attachmentUpdates.append(
                        existingQueueItem!.with(state: AttachmentState.synced.rawValue)
                    )
                } else {
                    // The localURI should be set if the record was meant to be downloaded
                    // and has been synced. If it's missing and hasSynced is false then
                    // it must be an upload operation
                    let newState = existingQueueItem!.localUri == nil ?
                        AttachmentState.queuedDownload.rawValue :
                        AttachmentState.queuedUpload.rawValue

                    attachmentUpdates.append(
                        existingQueueItem!.with(state: newState)
                    )
                }
            }
        }

        /**
         * Archive any items not specified in the watched items except for items pending delete.
         */
        for attachment in currentAttachments {
            if attachment.state != AttachmentState.queuedDelete.rawValue,
               items.first(where: { $0.id == attachment.id }) == nil
            {
                attachmentUpdates.append(
                    attachment.with(state: AttachmentState.archived.rawValue)
                )
            }
        }

        if !attachmentUpdates.isEmpty {
            try await attachmentsService.saveAttachments(attachments: attachmentUpdates)
        }
    }

    /// Saves a new file and schedules it for upload
    /// - Parameters:
    ///   - data: File data
    ///   - mediaType: MIME type
    ///   - fileExtension: File extension
    ///   - updateHook: Hook to assign attachment relationships in the same transaction
    /// - Returns: The created attachment
    public func saveFile(
        data: Data,
        mediaType: String,
        fileExtension: String?,
        updateHook: @escaping (PowerSyncTransaction, Attachment) throws -> Void
    ) async throws -> Attachment {
        let id = try await db.get(sql: "SELECT uuid() as id", parameters: [], mapper: { cursor in
            try cursor.getString(name: "id")
        })

        let filename = resolveNewAttachmentFilename(attachmentId: id, fileExtension: fileExtension)
        let localUri = getLocalUri(filename)

        // Write the file to the filesystem
        let fileSize = try await localStorage.saveFile(filePath: localUri, data: data)

        // Start a write transaction. The attachment record and relevant local relationship
        // assignment should happen in the same transaction.
        return try await db.writeTransaction { tx in
            let attachment = Attachment(
                id: id,
                filename: filename,
                state: AttachmentState.queuedUpload.rawValue,
                localUri: localUri,
                mediaType: mediaType,
                size: fileSize
            )

            // Allow consumers to set relationships to this attachment id
            try updateHook(tx, attachment)

            return try self.attachmentsService.upsertAttachment(attachment, context: tx)
        }
    }

    /// Queues a file for deletion
    /// - Parameters:
    ///   - attachmentId: ID of the attachment to delete
    ///   - updateHook: Hook to perform additional DB updates in the same transaction
    public func deleteFile(
        attachmentId: String,
        updateHook: @escaping (ConnectionContext, Attachment) throws -> Void
    ) async throws -> Attachment {
        guard let attachment = try await attachmentsService.getAttachment(id: attachmentId) else {
            throw NSError(domain: "AttachmentError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Attachment record with id \(attachmentId) was not found."])
        }

        return try await db.writeTransaction { tx in
            try updateHook(tx, attachment)

            let updatedAttachment = Attachment(
                id: attachment.id,
                filename: attachment.filename,
                state: AttachmentState.queuedDelete.rawValue,
                hasSynced: attachment.hasSynced,
                localUri: attachment.localUri,
                mediaType: attachment.mediaType,
                size: attachment.size,
            )

            return try self.attachmentsService.upsertAttachment(updatedAttachment, context: tx)
        }
    }

    /// Returns the local URI where a file is stored based on filename
    /// - Parameter filename: The name of the file
    /// - Returns: The file path
    public func getLocalUri(_ filename: String) -> String {
        return URL(fileURLWithPath: attachmentsDirectory).appendingPathComponent(filename).path
    }

    /// Removes all archived items
    public func expireCache() async throws {
        var done = false
        repeat {
            done = try await syncingService.deleteArchivedAttachments()
        } while !done
    }

    /// Clears the attachment queue and deletes all attachment files
    public func clearQueue() async throws {
        try await attachmentsService.clearQueue()
        // Remove the attachments directory
        try await localStorage.rmDir(path: attachmentsDirectory)
    }
}
