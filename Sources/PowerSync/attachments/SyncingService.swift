import Foundation
import Combine

/**
 * Service used to sync attachments between local and remote storage
 */
actor SyncingService {
    private let remoteStorage: RemoteStorageAdapter
    private let localStorage: LocalStorageAdapter
    private let attachmentsService: AttachmentService
    private let getLocalUri: (String) async -> String
    private let errorHandler: SyncErrorHandler?
//    private let logger: Logger
    private let syncThrottle: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private let syncTriggerSubject = PassthroughSubject<Void, Never>()
    private var periodicSyncTimer: Timer?
    private var syncTask: Task<Void, Never>?
    
    init(
        remoteStorage: RemoteStorageAdapter,
        localStorage: LocalStorageAdapter,
        attachmentsService: AttachmentService,
        getLocalUri: @escaping (String) async -> String,
        errorHandler: SyncErrorHandler? = nil,
//        logger: Logger,
        syncThrottle: TimeInterval = 5.0
    ) {
        self.remoteStorage = remoteStorage
        self.localStorage = localStorage
        self.attachmentsService = attachmentsService
        self.getLocalUri = getLocalUri
        self.errorHandler = errorHandler
//        self.logger = logger
        self.syncThrottle = syncThrottle
        
        // We use an actor for synchronisation.
        // This needs to be executed in a non-isolated environment during init
        Task { await self.setupSyncFlow() }
    }
    
    
    private func setupSyncFlow() {
        // Create a Task that will process sync events
        syncTask = Task {
            // Create an AsyncStream from the syncTriggerSubject
            let syncTrigger = AsyncStream<Void> { continuation in
                let cancellable = syncTriggerSubject
                    .throttle(for: .seconds(syncThrottle), scheduler: DispatchQueue.global(), latest: true)
                    .sink { _ in continuation.yield(()) }
                
                continuation.onTermination = { _ in
                    cancellable.cancel()
                }
                self.cancellables.insert(cancellable)
            }
            
            // Create a task that watches for active attachments
            let watchTask = Task {
                for try await _ in try attachmentsService.watchActiveAttachments() {
                    // When an attachment changes, trigger a sync
                    syncTriggerSubject.send(())
                }
            }
            
            // Process sync triggers
            for await _ in syncTrigger {
                guard !Task.isCancelled else { break }
                
                do {
                    // Process active attachments
                    let attachments = try await attachmentsService.getActiveAttachments()
                    try await handleSync(attachments: attachments)
                    
                    // Cleanup archived attachments
                    _ = try await deleteArchivedAttachments()
                } catch {
                    if error is CancellationError {
                        break
                    }
//                    logger.error("Caught exception when processing attachments: \(error)")
                }
            }
            
            // Clean up the watch task when we're done
            watchTask.cancel()
        }
    }
    
    func startPeriodicSync(period: TimeInterval) async {
        // Cancel existing timer if any
        if let timer = periodicSyncTimer {
            timer.invalidate()
            periodicSyncTimer = nil
        }
        
        // Create a new timer on the main actor and store the reference
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.triggerSync()
                }
            }
        
        // Trigger initial sync
        await triggerSync()
    }
    
    func triggerSync() async {
        // This is safe to call from outside the actor
        syncTriggerSubject.send(())
    }
    
    func close() async {
        // Cancel and clean up timer
        if let timer = periodicSyncTimer {
            timer.invalidate()
            periodicSyncTimer = nil
        }
        
        // Cancel the sync task
        syncTask?.cancel()
        syncTask = nil
        
        // Clean up Combine subscribers
        for cancellable in cancellables {
            cancellable.cancel()
        }
        cancellables.removeAll()
    }
    

    
    /**
     * Delete attachments that have been marked as archived
     */
    func deleteArchivedAttachments()  async throws -> Bool {
        return try await attachmentsService.deleteArchivedAttachments { pendingDelete in
            for attachment in pendingDelete {
                guard let localUri = attachment.localUri else {
                    continue
                }
                
                if  (try await false == self.localStorage.fileExists(filePath: localUri)) {
                    continue
                }
                
                try await self.localStorage.deleteFile(filePath: localUri)
            }
        }
    }
    
    /**
     * Handle downloading, uploading or deleting of attachments
     */
    private func handleSync(attachments: [Attachment]) async throws {
        var updatedAttachments = [Attachment]()
        
        do {
            for attachment in attachments {
                let state = AttachmentState(rawValue: attachment.state)
                
                switch state {
                case .queuedDownload:
//                    logger.info("Downloading \(attachment.filename)")
                    let updated = try await downloadAttachment(attachment: attachment)
                    updatedAttachments.append(updated)
                    
                case .queuedUpload:
//                    logger.info("Uploading \(attachment.filename)")
                    let updated = try await uploadAttachment(attachment: attachment)
                    updatedAttachments.append(updated)
                    
                case .queuedDelete:
//                    logger.info("Deleting \(attachment.filename)")
                    let updated = try await deleteAttachment(attachment: attachment)
                    updatedAttachments.append(updated)
                    
                default:
                    break
                }
            }
            
            // Update the state of processed attachments
            try await attachmentsService.saveAttachments(attachments: updatedAttachments)
        } catch {
            // We retry on the next invocation whenever there are errors at this level
//            logger.error("Error during sync: \(error.localizedDescription)")
            throw error
        }
    }
    
    /**
     * Upload attachment from local storage to remote storage.
     */
    private func uploadAttachment(attachment: Attachment) async throws -> Attachment {
        do {
            guard let localUri = attachment.localUri else {
                throw PowerSyncError.attachmentError("No localUri for attachment \(attachment.id)")
            }
            
            let fileData = try await localStorage.readFile(filePath: localUri)
            try await remoteStorage.uploadFile(fileData: fileData, attachment: attachment)
            
//            logger.info("Uploaded attachment \"\(attachment.id)\" to Cloud Storage")
            return attachment.with(state: AttachmentState.synced.rawValue, hasSynced: 1)
        } catch {
//            logger.error("Upload attachment error for attachment \(attachment.id): \(error.localizedDescription)")
            
            if let errorHandler = errorHandler {
                let shouldRetry = await errorHandler.onUploadError(attachment: attachment, error: error)
                if !shouldRetry {
//                    logger.info("Attachment with ID \(attachment.id) has been archived")
                    return attachment.with(state: AttachmentState.archived.rawValue)
                }
            }
            
            // Retry the upload (same state)
            return attachment
        }
    }
    
    /**
     * Download attachment from remote storage and save it to local storage.
     * Returns the updated state of the attachment.
     */
    private func downloadAttachment(attachment: Attachment) async throws -> Attachment {
        do {
            // When downloading an attachment we take the filename and resolve
            // the local_uri where the file will be stored
            let attachmentPath = await getLocalUri(attachment.filename)
            
            let fileData = try await remoteStorage.downloadFile(attachment: attachment)
            _ = try await localStorage.saveFile(filePath: attachmentPath, data: fileData)
            
//            logger.info("Downloaded file \"\(attachment.id)\"")
            
            // The attachment has been downloaded locally
            return attachment.with(
                state: AttachmentState.synced.rawValue,
                hasSynced: 1,
                localUri: attachmentPath,
            )
        } catch {
            if let errorHandler = errorHandler {
                let shouldRetry = await errorHandler.onDownloadError(attachment: attachment, error: error)
                if !shouldRetry {
//                    logger.info("Attachment with ID \(attachment.id) has been archived")
                    return attachment.with(state: AttachmentState.archived.rawValue)
                }
            }
            
//            logger.error("Download attachment error for attachment \(attachment.id): \(error.localizedDescription)")
            // Return the same state, this will cause a retry
            return attachment
        }
    }
    
    /**
     * Delete attachment from remote, local storage and then remove it from the queue.
     */
    private func deleteAttachment(attachment: Attachment) async throws -> Attachment {
        do {
            try await remoteStorage.deleteFile(attachment: attachment)
            
            if let localUri = attachment.localUri {
                try await localStorage.deleteFile(filePath: localUri)
            }
            
            return attachment.with(state: AttachmentState.archived.rawValue)
        } catch {
            if let errorHandler = errorHandler {
                let shouldRetry = await errorHandler.onDeleteError(attachment: attachment, error: error)
                if !shouldRetry {
//                    logger.info("Attachment with ID \(attachment.id) has been archived")
                    return attachment.with(state: AttachmentState.archived.rawValue)
                }
            }
            
            // We'll retry this
//            logger.error("Error deleting attachment: \(error.localizedDescription)")
            return attachment
        }
    }
}
