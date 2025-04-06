import Foundation

/**
 * Handles attachment operation errors.
 * The handlers here specify if the corresponding operations should be retried.
 * Attachment records are archived if an operation failed and should not be retried.
 */
public protocol SyncErrorHandler {
    /**
     * @returns if the provided attachment download operation should be retried
     */
    func onDownloadError(
        attachment: Attachment,
        error: Error
    ) async -> Bool
    
    /**
     * @returns if the provided attachment upload operation should be retried
     */
    func onUploadError(
        attachment: Attachment,
        error: Error
    ) async -> Bool
    
    /**
     * @returns if the provided attachment delete operation should be retried
     */
    func onDeleteError(
        attachment: Attachment,
        error: Error
    ) async -> Bool
}

/**
 * Default implementation of SyncErrorHandler
 */
public class DefaultSyncErrorHandler: SyncErrorHandler {
    public init() {}
    
    public func onDownloadError(attachment: Attachment, error: Error) async -> Bool {
        // Default implementation could log the error and determine retry based on error type
        return false // Don't retry by default
    }
    
    public func onUploadError(attachment: Attachment, error: Error) async -> Bool {
        // Default implementation could log the error and determine retry based on error type
        return false // Don't retry by default
    }
    
    public func onDeleteError(attachment: Attachment, error: Error) async -> Bool {
        // Default implementation could log the error and determine retry based on error type
        return false // Don't retry by default
    }
}
