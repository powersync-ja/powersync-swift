import Combine
import Foundation

/// Class used to implement the attachment queue
/// Requires a PowerSyncDatabase, a RemoteStorageAdapter implementation, and a directory name for attachments.
public class AttachmentQueue {
    /// Default name of the attachments table
    public static let defaultTableName = "attachments"

    let logTag = "AttachmentQueue"

    /// PowerSync database client
    public let db: PowerSyncDatabaseProtocol

    /// Remote storage adapter
    public let remoteStorage: RemoteStorageAdapter

    /// Directory name for attachments
    private let attachmentsDirectory: String

    /// Closure which creates a Stream of ``WatchedAttachmentItem``
    private let watchAttachments: () throws -> AsyncThrowingStream<[WatchedAttachmentItem], Error>

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
            return self.getLocalUri(filename)
        },
        errorHandler: self.errorHandler,
        syncThrottle: self.syncThrottleDuration
    )

    private let lock: LockActor

    /// Initializes the attachment queue
    /// - Parameters match the stored properties
    public init(
        db: PowerSyncDatabaseProtocol,
        remoteStorage: RemoteStorageAdapter,
        attachmentsDirectory: String,
        watchAttachments: @escaping () throws -> AsyncThrowingStream<[WatchedAttachmentItem], Error>,
        localStorage: LocalStorageAdapter = FileManagerStorageAdapter(),
        attachmentsQueueTableName: String = defaultTableName,
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
        self.watchAttachments = watchAttachments
        self.localStorage = localStorage
        self.attachmentsQueueTableName = attachmentsQueueTableName
        self.errorHandler = errorHandler
        self.syncInterval = syncInterval
        self.archivedCacheLimit = archivedCacheLimit
        self.syncThrottleDuration = syncThrottleDuration
        self.subdirectories = subdirectories
        self.downloadAttachments = downloadAttachments
        self.logger = logger ?? db.logger
        self.attachmentsService = AttachmentService(
            db: db,
            tableName: attachmentsQueueTableName,
            logger: self.logger,
            maxArchivedCount: archivedCacheLimit
        )
        self.lock = LockActor()
    }

    /// Starts the attachment sync process
    public func startSync() async throws {
        try await lock.withLock {
            try guardClosed()

            // Stop any active syncing before starting new Tasks
            try await _stopSyncing()

            // Ensure the directory where attachments are downloaded exists
            try await localStorage.makeDir(path: attachmentsDirectory)

            if let subdirectories = subdirectories {
                for subdirectory in subdirectories {
                    let path = URL(fileURLWithPath: attachmentsDirectory).appendingPathComponent(subdirectory).path
                    try await localStorage.makeDir(path: path)
                }
            }

            // Verify initial state
            try await attachmentsService.withContext { context in
                try await self.verifyAttachments(context: context)
            }

            try await syncingService.startSync(period: syncInterval)

            syncStatusTask = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // Add connectivity monitoring task
                        group.addTask {
                            var previousConnected = self.db.currentStatus.connected
                            for await status in self.db.currentStatus.asFlow() {
                                try Task.checkCancellation()
                                if !previousConnected && status.connected {
                                    try await self.syncingService.triggerSync()
                                }
                                previousConnected = status.connected
                            }
                        }

                        // Add attachment watching task
                        group.addTask {
                            for try await items in try self.watchAttachments() {
                                try await self.processWatchedAttachments(items: items)
                            }
                        }

                        // Wait for any task to complete (which should only happen on cancellation)
                        try await group.next()
                    }
                } catch {
                    if !(error is CancellationError) {
                        logger.error("Error in attachment sync job: \(error.localizedDescription)", tag: logTag)
                    }
                }
            }
        }
    }

    /// Stops active syncing tasks. Syncing can be resumed with ``startSync()``
    public func stopSyncing() async throws {
        try await lock.withLock {
            try await _stopSyncing()
        }
    }

    private func _stopSyncing() async throws {
        try guardClosed()

        syncStatusTask?.cancel()
        // Wait for the task to actually complete
        do {
            _ = try await syncStatusTask?.value
        } catch {
            // Task completed with error (likely cancellation)
            // This is okay
        }
        syncStatusTask = nil

        try await syncingService.stopSync()
    }

    /// Closes the attachment queue and cancels all sync tasks
    public func close() async throws {
        try await lock.withLock {
            try guardClosed()

            try await _stopSyncing()
            try await syncingService.close()
            closed = true
        }
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
        return "\(attachmentId).\(fileExtension ?? "attachment")"
    }

    /// Processes watched attachment items and updates sync state
    /// - Parameter items: List of watched attachment items
    public func processWatchedAttachments(items: [WatchedAttachmentItem]) async throws {
        // Need to get all the attachments which are tracked in the DB.
        // We might need to restore an archived attachment.
        try await attachmentsService.withContext { context in
            let currentAttachments = try await context.getAttachments()
            var attachmentUpdates = [Attachment]()

            for item in items {
                let existingQueueItem = currentAttachments.first { $0.id == item.id }

                if existingQueueItem == nil {
                    if !self.downloadAttachments {
                        continue
                    }
                    // This item should be added to the queue
                    // This item is assumed to be coming from an upstream sync
                    // Locally created new items should be persisted using saveFile before
                    // this point.
                    let filename = self.resolveNewAttachmentFilename(
                        attachmentId: item.id,
                        fileExtension: item.fileExtension
                    )

                    attachmentUpdates.append(
                        Attachment(
                            id: item.id,
                            filename: filename,
                            state: AttachmentState.queuedDownload
                        )
                    )
                } else if existingQueueItem!.state == AttachmentState.archived {
                    // The attachment is present again. Need to queue it for sync.
                    // We might be able to optimize this in future
                    if existingQueueItem!.hasSynced == 1 {
                        // No remote action required, we can restore the record (avoids deletion)
                        attachmentUpdates.append(
                            existingQueueItem!.with(state: AttachmentState.synced)
                        )
                    } else {
                        // The localURI should be set if the record was meant to be downloaded
                        // and has been synced. If it's missing and hasSynced is false then
                        // it must be an upload operation
                        let newState = existingQueueItem!.localUri == nil ?
                            AttachmentState.queuedDownload :
                            AttachmentState.queuedUpload

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
                if attachment.state != AttachmentState.queuedDelete,
                   items.first(where: { $0.id == attachment.id }) == nil
                {
                    attachmentUpdates.append(
                        attachment.with(state: AttachmentState.archived)
                    )
                }
            }

            if !attachmentUpdates.isEmpty {
                try await context.saveAttachments(attachments: attachmentUpdates)
            }
        }
    }

    /// Saves a new file and schedules it for upload
    /// - Parameters:
    ///   - data: File data
    ///   - mediaType: MIME type
    ///   - fileExtension: File extension
    ///   - updateHook: Hook to assign attachment relationships in the same transaction
    /// - Returns: The created attachment
    @discardableResult
    public func saveFile(
        data: Data,
        mediaType: String,
        fileExtension: String?,
        updateHook: @escaping (ConnectionContext, Attachment) throws -> Void
    ) async throws -> Attachment {
        let id = try await db.get(sql: "SELECT uuid() as id", parameters: [], mapper: { cursor in
            try cursor.getString(name: "id")
        })

        let filename = resolveNewAttachmentFilename(attachmentId: id, fileExtension: fileExtension)
        let localUri = getLocalUri(filename)

        // Write the file to the filesystem
        let fileSize = try await localStorage.saveFile(filePath: localUri, data: data)

        return try await attachmentsService.withContext { context in
            // Start a write transaction. The attachment record and relevant local relationship
            // assignment should happen in the same transaction.
            try await self.db.writeTransaction { tx in
                let attachment = Attachment(
                    id: id,
                    filename: filename,
                    state: AttachmentState.queuedUpload,
                    localUri: localUri,
                    mediaType: mediaType,
                    size: fileSize
                )

                // Allow consumers to set relationships to this attachment id
                try updateHook(tx, attachment)

                return try context.upsertAttachment(attachment, context: tx)
            }
        }
    }

    /// Queues a file for deletion
    /// - Parameters:
    ///   - attachmentId: ID of the attachment to delete
    ///   - updateHook: Hook to perform additional DB updates in the same transaction
    @discardableResult
    public func deleteFile(
        attachmentId: String,
        updateHook: @escaping (ConnectionContext, Attachment) throws -> Void
    ) async throws -> Attachment {
        try await attachmentsService.withContext { context in
            guard let attachment = try await context.getAttachment(id: attachmentId) else {
                throw PowerSyncAttachmentError.notFound("Attachment record with id \(attachmentId) was not found.")
            }

            let result = try await self.db.writeTransaction { tx in
                try updateHook(tx, attachment)

                let updatedAttachment = Attachment(
                    id: attachment.id,
                    filename: attachment.filename,
                    state: AttachmentState.queuedDelete,
                    hasSynced: attachment.hasSynced,
                    localUri: attachment.localUri,
                    mediaType: attachment.mediaType,
                    size: attachment.size
                )

                return try context.upsertAttachment(updatedAttachment, context: tx)
            }
            return result
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
        try await attachmentsService.withContext { context in
            var done = false
            repeat {
                done = try await self.syncingService.deleteArchivedAttachments(context)
            } while !done
        }
    }

    /// Clears the attachment queue and deletes all attachment files
    public func clearQueue() async throws {
        try await attachmentsService.withContext { context in
            try await context.clearQueue()
            // Remove the attachments directory
            try await self.localStorage.rmDir(path: self.attachmentsDirectory)
        }
    }

    /// Verifies attachment records are present in the filesystem
    private func verifyAttachments(context: AttachmentContext) async throws {
        let attachments = try await context.getAttachments()
        var updates: [Attachment] = []

        for attachment in attachments {
            guard let localUri = attachment.localUri else {
                continue
            }

            let exists = try await localStorage.fileExists(filePath: localUri)
            if attachment.state == AttachmentState.synced ||
                attachment.state == AttachmentState.queuedUpload &&
                !exists
            {
                // The file must have been removed from the local storage
                updates.append(attachment.with(
                    state: .archived,
                    localUri: .some(nil) // Clears the value
                ))
            }
        }

        try await context.saveAttachments(attachments: updates)
    }

    private func guardClosed() throws {
        if closed {
            throw PowerSyncAttachmentError.closed("Attachment queue is closed")
        }
    }
}
