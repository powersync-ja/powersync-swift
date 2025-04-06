import Foundation

/**
 * Adapter for interfacing with remote attachment storage.
 */
public protocol RemoteStorageAdapter {
    /**
     * Upload a file to remote storage
     */
    func uploadFile(
        fileData: Data,
        attachment: Attachment
    ) async throws
    
    /**
     * Download a file from remote storage
     */
    func downloadFile(attachment: Attachment) async throws -> Data
    
    /**
     * Delete a file from remote storage
     */
    func deleteFile(attachment: Attachment) async throws
}
