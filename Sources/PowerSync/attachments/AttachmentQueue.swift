import Foundation
import Combine
import OSLog

//TODO should not need this
import PowerSyncKotlin

/**
 * A watched attachment record item.
 * This is usually returned from watching all relevant attachment IDs.
 */
public struct WatchedAttachmentItem {
    /**
     * Id for the attachment record
     */
    public let id: String
    
    /**
     * File extension used to determine an internal filename for storage if no `filename` is provided
     */
    public let fileExtension: String?
    
    /**
     * Filename to store the attachment with
     */
    public let filename: String?
    
    public init(id: String, fileExtension: String? = nil, filename: String? = nil) {
        self.id = id
        self.fileExtension = fileExtension
        self.filename = filename
        
        precondition(fileExtension != nil || filename != nil, "Either fileExtension or filename must be provided.")
    }
}


/**
 * Class used to implement the attachment queue
 * Requires a PowerSyncDatabase, an implementation of
 * RemoteStorageAdapter and an attachment directory name which will
 * determine which folder attachments are stored into.
 */
public actor AttachmentQueue {
    public static let DEFAULT_TABLE_NAME = "attachments"
    public static let DEFAULT_ATTACHMENTS_DIRECTORY_NAME = "attachments"
    
    /**
     * PowerSync database client
     */
    public let db: PowerSyncDatabaseProtocol
    
    /**
     * Adapter which interfaces with the remote storage backend
     */
    public let remoteStorage: RemoteStorageAdapter
    
    /**
     * Directory name where attachment files will be written to disk.
     * This will be created if it does not exist
     */
    private let attachmentDirectory: String
    
    /**
     * A publisher for the current state of local attachments
     */
    private let watchedAttachments: AsyncThrowingStream<[WatchedAttachmentItem], Error>
    
    /**
     * Provides access to local filesystem storage methods
     */
    public let localStorage: LocalStorageAdapter
    
    /**
     * SQLite table where attachment state will be recorded
     */
    private let attachmentsQueueTableName: String
    
    /**
     * Attachment operation error handler. This specified if failed attachment operations
     * should be retried.
     */
    private let errorHandler: SyncErrorHandler?
    
    /**
     * Periodic interval to trigger attachment sync operations
     */
    private let syncInterval: TimeInterval
    
    /**
     * Archived attachments can be used as a cache which can be restored if an attachment id
     * reappears after being removed. This parameter defines how many archived records are retained.
     * Records are deleted once the number of items exceeds this value.
     */
    private let archivedCacheLimit: Int64
    
    /**
     * Throttles remote sync operations triggering
     */
    private let syncThrottleDuration: TimeInterval
    
    /**
     * Creates a list of subdirectories in the attachmentDirectory
     */
    private let subdirectories: [String]?
    
    /**
     * Should attachments be downloaded
     */
    private let downloadAttachments: Bool
    
    /**
     * Logging interface used for all log operations
     */
//    public let logger: Logger
    
    /**
     * Service which provides access to attachment records.
     * Use this to:
     *  - Query all current attachment records
     *  - Create new attachment records for upload/download
     */
    public let attachmentsService: AttachmentService
    
    private var syncStatusTask: Task<Void, Error>?
    private let mutex = NSLock()
    private var cancellables = Set<AnyCancellable>()
    
    public private(set) var closed: Bool = false
    
    /**
     * Syncing service for this attachment queue.
     * This processes attachment records and performs relevant upload, download and delete
     * operations.
     */
    private(set) lazy var syncingService: SyncingService = {
        return SyncingService(
            remoteStorage: self.remoteStorage,
            localStorage: self.localStorage,
            attachmentsService: self.attachmentsService,
            getLocalUri: { [weak self] filename in
                guard let self = self else { return filename }
                return await self.getLocalUri(filename)
            },
            errorHandler: self.errorHandler,
            syncThrottle: self.syncThrottleDuration
        )
    }()
    
    public init(
        db: PowerSyncDatabaseProtocol,
        remoteStorage: RemoteStorageAdapter,
        attachmentDirectory: String,
        watchedAttachments: AsyncThrowingStream<[WatchedAttachmentItem], Error>,
        localStorage: LocalStorageAdapter = FileManagerStorageAdapter(),
        attachmentsQueueTableName: String = DEFAULT_TABLE_NAME,
        errorHandler: SyncErrorHandler? = nil,
        syncInterval: TimeInterval = 30.0,
        archivedCacheLimit: Int64 = 100,
        syncThrottleDuration: TimeInterval = 1.0,
        subdirectories: [String]? = nil,
        downloadAttachments: Bool = true,
//        logger: Logger = Logger(subsystem: "com.powersync.attachments", category: "AttachmentQueue")
    ) {
        self.db = db
        self.remoteStorage = remoteStorage
        self.attachmentDirectory = attachmentDirectory
        self.watchedAttachments = watchedAttachments
        self.localStorage = localStorage
        self.attachmentsQueueTableName = attachmentsQueueTableName
        self.errorHandler = errorHandler
        self.syncInterval = syncInterval
        self.archivedCacheLimit = archivedCacheLimit
        self.syncThrottleDuration = syncThrottleDuration
        self.subdirectories = subdirectories
        self.downloadAttachments = downloadAttachments
//        self.logger = logger
        
        self.attachmentsService = AttachmentService(
            db: db,
            tableName: attachmentsQueueTableName,
//            logger: logger,
            maxArchivedCount: archivedCacheLimit
        )
    }
    
    /**
     * Initialize the attachment queue by
     * 1. Creating attachments directory
     * 2. Adding watches for uploads, downloads, and deletes
     * 3. Adding trigger to run uploads, downloads, and deletes when device is online after being offline
     */
    public func startSync() async throws {
        if closed {
            throw NSError(domain: "AttachmentError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Attachment queue has been closed"])
        }
        
        // Ensure the directory where attachments are downloaded exists
        try await localStorage.makeDir(path: attachmentDirectory)
        
        if let subdirectories = subdirectories {
            for subdirectory in subdirectories {
                let path = URL(fileURLWithPath: attachmentDirectory).appendingPathComponent(subdirectory).path
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
//                    logger.error("Error in sync job: \(error.localizedDescription)")
                }
            }
        }
    }
    
    public func close() async throws {
        if closed {
            return
        }
        
        syncStatusTask?.cancel()
        await syncingService.close()
        closed = true
    }
    
    /**
     * Resolves the filename for new attachment items.
     * A new attachment from watchedAttachments might not include a filename.
     * Concatenates the attachment ID and extension by default.
     * This method can be overridden for custom behavior.
     */
    public func resolveNewAttachmentFilename(
        attachmentId: String,
        fileExtension: String?
    ) -> String {
        return "\(attachmentId).\(fileExtension ?? "")"
    }
    
    /**
     * Processes attachment items returned from watchedAttachments.
     * The default implementation asserts the items returned from watchedAttachments as the definitive
     * state for local attachments.
     *
     * Records currently in the attachment queue which are not present in the items are deleted from
     * the queue.
     *
     * Received items which are not currently in the attachment queue are assumed scheduled for
     * download. This requires that locally created attachments should be created with saveFile
     * before assigning the attachment ID to the relevant watched tables.
     *
     * This method can be overridden for custom behavior.
     */
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
                    /**
                     * The localURI should be set if the record was meant to be downloaded
                     * and has been synced. If it's missing and hasSynced is false then
                     * it must be an upload operation
                     */
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
            if attachment.state != AttachmentState.queuedDelete.rawValue &&
               items.first(where: { $0.id == attachment.id }) == nil {
                attachmentUpdates.append(
                    attachment.with(state: AttachmentState.archived.rawValue)
                )
            }
        }
        
        if !attachmentUpdates.isEmpty {
            try await attachmentsService.saveAttachments(attachments: attachmentUpdates)
        }
    }
    
    /**
     * A function which creates a new attachment locally. This new attachment is queued for upload
     * after creation.
     *
     * The filename is resolved using resolveNewAttachmentFilename.
     *
     * A updateHook is provided which should be used when assigning relationships to the newly
     * created attachment. This hook is executed in the same writeTransaction which creates the
     * attachment record.
     *
     * This method can be overridden for custom behavior.
     */
    public func saveFile(
        data: Data,
        mediaType: String,
        fileExtension: String?,
        updateHook: ((PowerSyncTransaction, Attachment) throws -> Void)? = nil
    ) async throws -> Attachment {
        let id = try await db.get(sql: "SELECT uuid() as id", parameters: [], mapper: { cursor in
            try cursor.getString(name: "id") })
        
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
            try updateHook?(tx, attachment)
            
            return try self.attachmentsService.upsertAttachment(attachment, context: tx)
        }
    }
    
    /**
     * A function which creates an attachment delete operation locally. This operation is queued
     * for delete.
     * The default implementation assumes the attachment record already exists locally. An exception
     * is thrown if the record does not exist locally.
     * This method can be overridden for custom behavior.
     */
    public func deleteFile(
        attachmentId: String,
        updateHook: ((ConnectionContext, Attachment) throws -> Void)? = nil
    ) async throws -> Attachment {
        guard let attachment = try await attachmentsService.getAttachment(id: attachmentId) else {
            throw NSError(domain: "AttachmentError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Attachment record with id \(attachmentId) was not found."])
        }
        
        return try await db.writeTransaction { tx in
            try updateHook?(tx, attachment)
            
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
    
    /**
     * Return user's storage directory with the attachmentPath used to load the file.
     * Example: filePath: "attachment-1.jpg" returns "/path/to/Documents/attachments/attachment-1.jpg"
     */
    public func getLocalUri(_ filename: String) -> String {
        return URL(fileURLWithPath: attachmentDirectory).appendingPathComponent(filename).path
    }
    
    /**
     * Removes all archived items
     */
    public func expireCache() async throws {
        var done = false
        repeat {
            done = try await self.syncingService.deleteArchivedAttachments()
        } while !done
    }
    
    /**
     * Clears the attachment queue and deletes all attachment files
     */
    public func clearQueue() async throws {
        try await attachmentsService.clearQueue()
        // Remove the attachments directory
        try await localStorage.rmDir(path: attachmentDirectory)
    }
}
