import Foundation

/// Adapter for interfacing with remote attachment storage.
public protocol RemoteStorageAdapter {
    /// Uploads a file to remote storage.
    ///
    /// - Parameters:
    ///   - fileData: The binary content of the file to upload.
    ///   - attachment: The associated `Attachment` metadata describing the file.
    /// - Throws: An error if the upload fails.
    func uploadFile(
        fileData: Data,
        attachment: Attachment
    ) async throws

    /// Downloads a file from remote storage.
    ///
    /// - Parameter attachment: The `Attachment` describing the file to download.
    /// - Returns: The binary data of the downloaded file.
    /// - Throws: An error if the download fails or the file is not found.
    func downloadFile(attachment: Attachment) async throws -> Data

    /// Deletes a file from remote storage.
    ///
    /// - Parameter attachment: The `Attachment` describing the file to delete.
    /// - Throws: An error if the deletion fails or the file does not exist.
    func deleteFile(attachment: Attachment) async throws
}
