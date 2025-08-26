import Foundation

/// Handles attachment operation errors.
///
/// The handlers defined in this protocol specify whether corresponding attachment
/// operations (download, upload, delete) should be retried upon failure.
///
/// If an operation fails and should not be retried, the attachment record is archived.
public protocol SyncErrorHandler {
    /// Handles a download error for a specific attachment.
    ///
    /// - Parameters:
    ///   - attachment: The `Attachment` that failed to download.
    ///   - error: The error encountered during the download operation.
    /// - Returns: `true` if the operation should be retried, `false` if it should be archived.
    func onDownloadError(
        attachment: Attachment,
        error: Error
    ) async -> Bool

    /// Handles an upload error for a specific attachment.
    ///
    /// - Parameters:
    ///   - attachment: The `Attachment` that failed to upload.
    ///   - error: The error encountered during the upload operation.
    /// - Returns: `true` if the operation should be retried, `false` if it should be archived.
    func onUploadError(
        attachment: Attachment,
        error: Error
    ) async -> Bool

    /// Handles a delete error for a specific attachment.
    ///
    /// - Parameters:
    ///   - attachment: The `Attachment` that failed to be deleted.
    ///   - error: The error encountered during the delete operation.
    /// - Returns: `true` if the operation should be retried, `false` if it should be archived.
    func onDeleteError(
        attachment: Attachment,
        error: Error
    ) async -> Bool
}

/// Default implementation of `SyncErrorHandler`.
///
/// By default, all operations return `false`, indicating no retry.
public class DefaultSyncErrorHandler: SyncErrorHandler {
    public init() {}

    public func onDownloadError(attachment _: Attachment, error _: Error) async -> Bool {
        // Default: do not retry failed downloads
        return false
    }

    public func onUploadError(attachment _: Attachment, error _: Error) async -> Bool {
        // Default: do not retry failed uploads
        return false
    }

    public func onDeleteError(attachment _: Attachment, error _: Error) async -> Bool {
        // Default: do not retry failed deletions
        return false
    }
}
