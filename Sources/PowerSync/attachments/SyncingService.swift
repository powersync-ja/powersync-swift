import Foundation
import Combine

/// A service that synchronizes attachments between local and remote storage.
///
/// This actor watches for changes to active attachments and performs queued
/// download, upload, and delete operations. Syncs can be triggered manually,
/// periodically, or based on database changes.
actor SyncingService {
    private let remoteStorage: RemoteStorageAdapter
    private let localStorage: LocalStorageAdapter
    private let attachmentsService: AttachmentService
    private let getLocalUri: (String) async -> String
    private let errorHandler: SyncErrorHandler?
    private let syncThrottle: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private let syncTriggerSubject = PassthroughSubject<Void, Never>()
    private var periodicSyncTimer: Timer?
    private var syncTask: Task<Void, Never>?

    /// Initializes a new instance of `SyncingService`.
    ///
    /// - Parameters:
    ///   - remoteStorage: Adapter for remote storage access.
    ///   - localStorage: Adapter for local storage access.
    ///   - attachmentsService: Service for querying and updating attachments.
    ///   - getLocalUri: Callback used to resolve a local path for saving downloaded attachments.
    ///   - errorHandler: Optional handler to determine if sync errors should be retried.
    ///   - syncThrottle: Throttle interval to control frequency of sync triggers.
    init(
        remoteStorage: RemoteStorageAdapter,
        localStorage: LocalStorageAdapter,
        attachmentsService: AttachmentService,
        getLocalUri: @escaping (String) async -> String,
        errorHandler: SyncErrorHandler? = nil,
        syncThrottle: TimeInterval = 5.0
    ) {
        self.remoteStorage = remoteStorage
        self.localStorage = localStorage
        self.attachmentsService = attachmentsService
        self.getLocalUri = getLocalUri
        self.errorHandler = errorHandler
        self.syncThrottle = syncThrottle

        Task { await self.setupSyncFlow() }
    }

    /// Sets up the main attachment syncing pipeline and starts watching for changes.
    private func setupSyncFlow() {
        syncTask = Task {
            let syncTrigger = AsyncStream<Void> { continuation in
                let cancellable = syncTriggerSubject
                    .throttle(for: .seconds(syncThrottle), scheduler: DispatchQueue.global(), latest: true)
                    .sink { _ in continuation.yield(()) }

                continuation.onTermination = { _ in
                    cancellable.cancel()
                }
                self.cancellables.insert(cancellable)
            }

            let watchTask = Task {
                for try await _ in try attachmentsService.watchActiveAttachments() {
                    syncTriggerSubject.send(())
                }
            }

            for await _ in syncTrigger {
                guard !Task.isCancelled else { break }

                do {
                    let attachments = try await attachmentsService.getActiveAttachments()
                    try await handleSync(attachments: attachments)
                    _ = try await deleteArchivedAttachments()
                } catch {
                    if error is CancellationError { break }
                    // logger.error("Sync failure: \(error)")
                }
            }

            watchTask.cancel()
        }
    }

    /// Starts periodic syncing of attachments.
    ///
    /// - Parameter period: The time interval in seconds between each sync.
    func startPeriodicSync(period: TimeInterval) async {
        if let timer = periodicSyncTimer {
            timer.invalidate()
            periodicSyncTimer = nil
        }

        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.triggerSync() }
        }

        await triggerSync()
    }

    /// Triggers a sync operation. Can be called manually.
    func triggerSync() async {
        syncTriggerSubject.send(())
    }

    /// Cleans up internal resources and cancels any ongoing syncing.
    func close() async {
        if let timer = periodicSyncTimer {
            timer.invalidate()
            periodicSyncTimer = nil
        }

        syncTask?.cancel()
        syncTask = nil

        for cancellable in cancellables {
            cancellable.cancel()
        }
        cancellables.removeAll()
    }

    /// Deletes attachments marked as archived that exist on local storage.
    ///
    /// - Returns: `true` if any deletions occurred, `false` otherwise.
    func deleteArchivedAttachments() async throws -> Bool {
        return try await attachmentsService.deleteArchivedAttachments { pendingDelete in
            for attachment in pendingDelete {
                guard let localUri = attachment.localUri else { continue }
                if try await !self.localStorage.fileExists(filePath: localUri) { continue }
                try await self.localStorage.deleteFile(filePath: localUri)
            }
        }
    }

    /// Handles syncing for a given list of attachments.
    ///
    /// This includes queued downloads, uploads, and deletions.
    ///
    /// - Parameter attachments: The attachments to process.
    private func handleSync(attachments: [Attachment]) async throws {
        var updatedAttachments = [Attachment]()

        for attachment in attachments {
            let state = AttachmentState(rawValue: attachment.state)

            switch state {
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

        try await attachmentsService.saveAttachments(attachments: updatedAttachments)
    }

    /// Uploads an attachment to remote storage.
    ///
    /// - Parameter attachment: The attachment to upload.
    /// - Returns: The updated attachment with new sync state.
    private func uploadAttachment(attachment: Attachment) async throws -> Attachment {
        do {
            guard let localUri = attachment.localUri else {
                throw PowerSyncError.attachmentError("No localUri for attachment \(attachment.id)")
            }

            let fileData = try await localStorage.readFile(filePath: localUri)
            try await remoteStorage.uploadFile(fileData: fileData, attachment: attachment)

            return attachment.with(state: AttachmentState.synced.rawValue, hasSynced: 1)
        } catch {
            if let errorHandler = errorHandler {
                let shouldRetry = await errorHandler.onUploadError(attachment: attachment, error: error)
                if !shouldRetry {
                    return attachment.with(state: AttachmentState.archived.rawValue)
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
        do {
            let attachmentPath = await getLocalUri(attachment.filename)
            let fileData = try await remoteStorage.downloadFile(attachment: attachment)
            _ = try await localStorage.saveFile(filePath: attachmentPath, data: fileData)

            return attachment.with(
                state: AttachmentState.synced.rawValue,
                hasSynced: 1,
                localUri: attachmentPath
            )
        } catch {
            if let errorHandler = errorHandler {
                let shouldRetry = await errorHandler.onDownloadError(attachment: attachment, error: error)
                if !shouldRetry {
                    return attachment.with(state: AttachmentState.archived.rawValue)
                }
            }
            return attachment
        }
    }

    /// Deletes an attachment from remote and local storage.
    ///
    /// - Parameter attachment: The attachment to delete.
    /// - Returns: The updated attachment with archived state.
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
                    return attachment.with(state: AttachmentState.archived.rawValue)
                }
            }
            return attachment
        }
    }
}
