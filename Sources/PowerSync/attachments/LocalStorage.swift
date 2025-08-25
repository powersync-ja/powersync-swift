import Foundation

/// Error type for PowerSync operations
public enum PowerSyncAttachmentError: Error {
    /// A general error with an associated message
    case generalError(String)

    /// Indicates no matching attachment record could be found
    case notFound(String)

    /// Indicates that a file was not found at the given path
    case fileNotFound(String)

    /// An I/O error occurred
    case ioError(Error)

    /// The given file or directory path was invalid
    case invalidPath(String)

    /// The attachments queue or sub services have been closed
    case closed(String)
}

/// Protocol defining an adapter interface for local file storage
public protocol LocalStorageAdapter: Sendable {
    /// Saves data to a file at the specified path.
    ///
    /// - Parameters:
    ///   - filePath: The full path where the file should be saved.
    ///   - data: The binary data to save.
    /// - Returns: The byte size of the saved file.
    /// - Throws: `PowerSyncAttachmentError` if saving fails.
    func saveFile(
        filePath: String,
        data: Data
    ) async throws -> Int64

    /// Reads a file from the specified path.
    ///
    /// - Parameters:
    ///   - filePath: The full path to the file.
    ///   - mediaType: An optional media type (MIME type) to help determine how to handle the file.
    /// - Returns: The contents of the file as `Data`.
    /// - Throws: `PowerSyncAttachmentError` if reading fails or the file doesn't exist.
    func readFile(
        filePath: String,
        mediaType: String?
    ) async throws -> Data

    /// Deletes a file at the specified path.
    ///
    /// - Parameter filePath: The full path to the file to delete.
    /// - Throws: `PowerSyncAttachmentError` if deletion fails or file doesn't exist.
    func deleteFile(filePath: String) async throws

    /// Checks if a file exists at the specified path.
    ///
    /// - Parameter filePath: The path to the file.
    /// - Returns: `true` if the file exists, `false` otherwise.
    /// - Throws: `PowerSyncAttachmentError` if checking fails.
    func fileExists(filePath: String) async throws -> Bool

    /// Creates a directory at the specified path.
    ///
    /// - Parameter path: The full path to the directory.
    /// - Throws: `PowerSyncAttachmentError` if creation fails.
    func makeDir(path: String) async throws

    /// Removes a directory at the specified path.
    ///
    /// - Parameter path: The full path to the directory.
    /// - Throws: `PowerSyncAttachmentError` if removal fails.
    func rmDir(path: String) async throws

    /// Copies a file from the source path to the target path.
    ///
    /// - Parameters:
    ///   - sourcePath: The original file path.
    ///   - targetPath: The destination file path.
    /// - Throws: `PowerSyncAttachmentError` if the copy operation fails.
    func copyFile(
        sourcePath: String,
        targetPath: String
    ) async throws
}

/// Extension providing a default implementation of `readFile` without a media type
public extension LocalStorageAdapter {
    /// Reads a file from the specified path without specifying a media type.
    ///
    /// - Parameter filePath: The full path to the file.
    /// - Returns: The contents of the file as `Data`.
    /// - Throws: `PowerSyncAttachmentError` if reading fails.
    func readFile(filePath: String) async throws -> Data {
        return try await readFile(filePath: filePath, mediaType: nil)
    }
}
