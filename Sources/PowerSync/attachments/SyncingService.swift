import Combine
import Foundation

/// A service that synchronizes attachments between local and remote storage.
///
/// This watches for changes to active attachments and performs queued
/// download, upload, and delete operations. Syncs can be triggered manually,
/// periodically, or based on database changes.
public protocol SyncingService: Sendable {
    /// Starts periodic syncing of attachments.
    ///
    /// - Parameter period: The time interval in seconds between each sync.
    func startSync(period: TimeInterval) async throws

    func stopSync() async throws

    /// Cleans up internal resources and cancels any ongoing syncing.
    func close() async throws

    /// Triggers a sync operation. Can be called manually.
    func triggerSync() async throws

    /// Deletes attachments marked as archived that exist on local storage.
    ///
    /// - Returns: `true` if any deletions occurred, `false` otherwise.
    func deleteArchivedAttachments(_ context: AttachmentContext) async throws -> Bool
}

actor SyncingServiceImpl: SyncingService {
    private let remoteStorage: RemoteStorageAdapter
    private let localStorage: LocalStorageAdapter
    private let attachmentsService: AttachmentService
    private let getLocalUri: @Sendable (String) async -> String
    private let errorHandler: SyncErrorHandler?
    private let syncThrottle: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private let syncTriggerSubject = PassthroughSubject<Void, Never>()
    private var periodicSyncTimer: Timer?
    private var syncTask: Task<Void, Never>?
    let logger: any LoggerProtocol

    let logTag = "AttachmentSync"
    var closed: Bool

    /// Initializes a new instance of `SyncingService`.
    ///
    /// - Parameters:
    ///   - remoteStorage: Adapter for remote storage access.
    ///   - localStorage: Adapter for local storage access.
    ///   - attachmentsService: Service for querying and updating attachments.
    ///   - getLocalUri: Callback used to resolve a local path for saving downloaded attachments.
    ///   - errorHandler: Optional handler to determine if sync errors should be retried.
    ///   - syncThrottle: Throttle interval to control frequency of sync triggers.
    public init(
        remoteStorage: RemoteStorageAdapter,
        localStorage: LocalStorageAdapter,
        attachmentsService: AttachmentService,
        logger: any LoggerProtocol,
        getLocalUri: @Sendable @escaping (String) async -> String,
        errorHandler: SyncErrorHandler? = nil,
        syncThrottle: TimeInterval = 5.0
    ) {
        self.remoteStorage = remoteStorage
        self.localStorage = localStorage
        self.attachmentsService = attachmentsService
        self.getLocalUri = getLocalUri
        self.errorHandler = errorHandler
        self.syncThrottle = syncThrottle
        self.logger = logger
        closed = false
    }

    /// Starts periodic syncing of attachments.
    ///
    /// - Parameter period: The time interval in seconds between each sync.
    public func startSync(period: TimeInterval) async throws {
        try guardClosed()

        // Close any active sync operations
        try await _stopSync()

        setupSyncFlow(period: period)
    }

    public func stopSync() async throws {
        try guardClosed()
        try await _stopSync()
    }

    private func _stopSync() async throws {
        if let timer = periodicSyncTimer {
            timer.invalidate()
            periodicSyncTimer = nil
        }

        syncTask?.cancel()

        // Wait for the task to actually complete
        _ = await syncTask?.value
        syncTask = nil

        for cancellable in cancellables {
            cancellable.cancel()
        }
        cancellables.removeAll()
    }

    /// Cleans up internal resources and cancels any ongoing syncing.
    func close() async throws {
        try guardClosed()

        try await _stopSync()
        _setClosed()
    }

    /// Triggers a sync operation. Can be called manually.
    func triggerSync() async throws {
        try guardClosed()
        syncTriggerSubject.send(())
    }

    /// Deletes attachments marked as archived that exist on local storage.
    ///
    /// - Returns: `true` if any deletions occurred, `false` otherwise.
    func deleteArchivedAttachments(_ context: AttachmentContext) async throws -> Bool {
        return try await context.deleteArchivedAttachments { pendingDelete in
            for attachment in pendingDelete {
                guard let localUri = attachment.localUri else { continue }
                if try await !self.localStorage.fileExists(filePath: localUri) { continue }
                try await self.localStorage.deleteFile(filePath: localUri)
            }
        }
    }

    private func guardClosed() throws {
        if closed {
            throw PowerSyncAttachmentError.closed("Syncing service is closed")
        }
    }

    private func createSyncTrigger() -> AsyncStream<Void> {
        AsyncStream<Void> { continuation in
            let cancellable = syncTriggerSubject
                .throttle(
                    for: .seconds(syncThrottle),
                    scheduler: DispatchQueue.global(),
                    latest: true
                )
                .sink { _ in continuation.yield(()) }

            continuation.onTermination = { _ in
                continuation.finish()
            }
            self.cancellables.insert(cancellable)
        }
    }

    /// Sets up the main attachment syncing pipeline and starts watching for changes.
    private func setupSyncFlow(period: TimeInterval) {
        syncTask = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Handle sync trigger events
                    group.addTask {
                        let syncTrigger = await self.createSyncTrigger()

                        for await _ in syncTrigger {
                            try Task.checkCancellation()

                            try await self.attachmentsService.withContext { context in
                                let attachments = try await context.getActiveAttachments()
                                try await self.handleSync(context: context, attachments: attachments)
                                _ = try await self.deleteArchivedAttachments(context)
                            }
                        }
                    }

                    // Watch attachment records. Trigger a sync on change
                    group.addTask {
                        for try await _ in try await self.attachmentsService.watchActiveAttachments() {
                            try Task.checkCancellation()
                            await self._triggerSyncSubject()
                        }
                    }

                    group.addTask {
                        let delay = UInt64(period * 1_000_000_000)
                        while !Task.isCancelled {
                            try await Task.sleep(nanoseconds: delay)
                            try await self.triggerSync()
                        }
                    }

                    // Wait for any task to complete
                    try await group.next()
                }
            } catch {
                if !(error is CancellationError) {
                    logger.error("Sync error: \(error)", tag: logTag)
                }
            }
        }
    }

    /// Handles syncing for a given list of attachments.
    ///
    /// This includes queued downloads, uploads, and deletions.
    ///
    /// - Parameter attachments: The attachments to process.
    private func handleSync(context: AttachmentContext, attachments: [Attachment]) async throws {
        var updatedAttachments = [Attachment]()

        for attachment in attachments {
            switch attachment.state {
            case .queuedDownload:
                let updated = try await downloadAttachment(attachment: attachment)
                updatedAttachments.append(updated)
            case .queuedUpload:
                let updated = try await uploadAttachment(attachment: attachment)
                updatedAttachments.append(updated)
            case .queuedDelete:
                let updated = try await deleteAttachment(attachment: attachment)
                updatedAttachments.append(updated)
            default:
                break
            }
        }

        try await context.saveAttachments(attachments: updatedAttachments)
    }

    /// Uploads an attachment to remote storage.
    ///
    /// - Parameter attachment: The attachment to upload.
    /// - Returns: The updated attachment with new sync state.
    private func uploadAttachment(attachment: Attachment) async throws -> Attachment {
        logger.info("Uploading attachment \(attachment.filename)", tag: logTag)
        do {
            guard let localUri = attachment.localUri else {
                throw PowerSyncAttachmentError.generalError("No localUri for attachment \(attachment.id)")
            }

            let fileData = try await localStorage.readFile(filePath: localUri)
            try await remoteStorage.uploadFile(fileData: fileData, attachment: attachment)

            return attachment.with(state: AttachmentState.synced, hasSynced: true)
        } catch {
            if let errorHandler = errorHandler {
                let shouldRetry = await errorHandler.onUploadError(attachment: attachment, error: error)
                if !shouldRetry {
                    return attachment.with(state: AttachmentState.archived)
                }
            }
            return attachment
        }
    }

    /// Downloads an attachment from remote storage and stores it locally.
    ///
    /// - Parameter attachment: The attachment to download.
    /// - Returns: The updated attachment with new sync state.
    private func downloadAttachment(attachment: Attachment) async throws -> Attachment {
        logger.info("Downloading attachment \(attachment.filename)", tag: logTag)
        do {
            let attachmentPath = await getLocalUri(attachment.filename)
            let fileData = try await remoteStorage.downloadFile(attachment: attachment)
            _ = try await localStorage.saveFile(filePath: attachmentPath, data: fileData)

            return attachment.with(
                state: AttachmentState.synced,
                hasSynced: true,
                localUri: attachmentPath
            )
        } catch {
            if let errorHandler = errorHandler {
                let shouldRetry = await errorHandler.onDownloadError(attachment: attachment, error: error)
                if !shouldRetry {
                    return attachment.with(state: AttachmentState.archived)
                }
            }
            return attachment
        }
    }

    /// Small actor isolated method to trigger the sync subject
    private func _triggerSyncSubject() {
        syncTriggerSubject.send(())
    }

    /// Small actor isolated method to mark as closed
    private func _setClosed() {
        closed = true
    }

    /// Deletes an attachment from remote and local storage.
    ///
    /// - Parameter attachment: The attachment to delete.
    /// - Returns: The updated attachment with archived state.
    private func deleteAttachment(attachment: Attachment) async throws -> Attachment {
        logger.info("Deleting attachment \(attachment.filename)", tag: logTag)
        do {
            try await remoteStorage.deleteFile(attachment: attachment)

            if let localUri = attachment.localUri {
                try await localStorage.deleteFile(filePath: localUri)
            }

            return attachment.with(state: AttachmentState.archived)
        } catch {
            if let errorHandler = errorHandler {
                let shouldRetry = await errorHandler.onDeleteError(attachment: attachment, error: error)
                if !shouldRetry {
                    return attachment.with(state: AttachmentState.archived)
                }
            }
            return attachment
        }
    }
}
